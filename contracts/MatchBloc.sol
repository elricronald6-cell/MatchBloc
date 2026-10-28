// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title MatchBloc
 * @notice Matching-fund rounds on BOT Chain.
 *
 * A sponsor seeds a matching pool and opens a round. Projects register.
 * Anyone can back a project with BOT. When the round closes, the pool is
 * split between projects **by how many distinct wallets backed them**, not by
 * how much those wallets gave.
 *
 * That one choice is the whole design. Ten people giving 1 BOT each pull ten
 * times the match of one person giving 10 BOT. The pool rewards reach, and
 * a single large backer cannot buy the match.
 *
 * Settlement is permissionless — anyone can close a round once its clock runs
 * out, so a sponsor cannot strand the pool by going quiet.
 */
contract MatchBloc is Ownable, Pausable, ReentrancyGuard {
    struct Round {
        address sponsor;
        uint256 pool;
        uint64 endsAt;
        bool settled;
        uint32 projectCount;
        uint256 totalBackers;
        string name;
    }

    struct Project {
        uint64 roundId;
        address owner;
        uint256 raised;
        uint32 backers;
        uint256 matched;
        bool claimed;
        string name;
    }

    uint64 public constant MIN_DURATION = 1 days;
    uint64 public constant MAX_DURATION = 90 days;
    uint256 public constant MIN_POOL = 0.1 ether;
    /// @dev Keeps the settle loop bounded and cheap.
    uint32 public constant MAX_PROJECTS = 64;
    uint256 public constant MAX_NAME = 56;
    uint16 public constant MAX_FEE_BPS = 500;

    /// @notice Taken once, at claim time, from raised + matched.
    uint16 public feeBps = 250;

    uint256 public accumulatedFees;
    /// @notice Pools and contributions not yet claimed or refunded.
    uint256 public lockedTotal;

    Round[] private _rounds;
    Project[] private _projects;

    mapping(uint256 => uint256[]) private _roundProjects;
    mapping(uint256 => mapping(address => uint256)) private _contributed;
    mapping(address => uint256[]) private _projectsByOwner;

    event RoundCreated(uint256 indexed roundId, address indexed sponsor, string name, uint256 pool, uint64 endsAt);
    event ProjectRegistered(uint256 indexed projectId, uint256 indexed roundId, address indexed owner, string name);
    event Backed(uint256 indexed projectId, address indexed backer, uint256 amount, bool firstTime);
    event RoundSettled(uint256 indexed roundId, address indexed settler, uint256 distributed, uint256 dust);
    event PoolRefunded(uint256 indexed roundId, address indexed sponsor, uint256 amount);
    event Claimed(uint256 indexed projectId, address indexed owner, uint256 raised, uint256 matched, uint256 fee);
    event FeeUpdated(uint16 feeBps);
    event FeesWithdrawn(address indexed to, uint256 amount);

    constructor() Ownable(msg.sender) {}

    // -------------------------------------------------------------- rounds

    function createRound(string calldata name, uint64 durationSecs)
        external
        payable
        whenNotPaused
        returns (uint256 roundId)
    {
        require(bytes(name).length > 0 && bytes(name).length <= MAX_NAME, "bad name");
        require(durationSecs >= MIN_DURATION && durationSecs <= MAX_DURATION, "bad duration");
        require(msg.value >= MIN_POOL, "pool too small");

        roundId = _rounds.length;
        _rounds.push(
            Round({
                sponsor: msg.sender,
                pool: msg.value,
                endsAt: uint64(block.timestamp) + durationSecs,
                settled: false,
                projectCount: 0,
                totalBackers: 0,
                name: name
            })
        );
        lockedTotal += msg.value;
        emit RoundCreated(roundId, msg.sender, name, msg.value, _rounds[roundId].endsAt);
    }

    function registerProject(uint256 roundId, string calldata name)
        external
        whenNotPaused
        returns (uint256 projectId)
    {
        Round storage r = _round(roundId);
        require(block.timestamp < r.endsAt, "round closed");
        require(!r.settled, "settled");
        require(r.projectCount < MAX_PROJECTS, "round full");
        require(bytes(name).length > 0 && bytes(name).length <= MAX_NAME, "bad name");

        projectId = _projects.length;
        _projects.push(
            Project({
                roundId: uint64(roundId),
                owner: msg.sender,
                raised: 0,
                backers: 0,
                matched: 0,
                claimed: false,
                name: name
            })
        );
        _roundProjects[roundId].push(projectId);
        _projectsByOwner[msg.sender].push(projectId);
        unchecked {
            r.projectCount += 1;
        }
        emit ProjectRegistered(projectId, roundId, msg.sender, name);
    }

    // ------------------------------------------------------------- backing

    /**
     * @notice Back a project. The first contribution from an address is what
     *         earns match weight; topping up adds to the project's raised
     *         total but not to its backer count.
     */
    function back(uint256 projectId) external payable whenNotPaused {
        Project storage p = _project(projectId);
        Round storage r = _rounds[p.roundId];
        require(block.timestamp < r.endsAt, "round closed");
        require(!r.settled, "settled");
        require(msg.value > 0, "nothing sent");
        require(msg.sender != p.owner, "owner cannot back");

        bool firstTime = _contributed[projectId][msg.sender] == 0;
        _contributed[projectId][msg.sender] += msg.value;
        p.raised += msg.value;
        lockedTotal += msg.value;

        if (firstTime) {
            unchecked {
                p.backers += 1;
            }
            r.totalBackers += 1;
        }
        emit Backed(projectId, msg.sender, msg.value, firstTime);
    }

    // ---------------------------------------------------------- settlement

    /**
     * @notice Close a round and fix every project's match. Anyone may call it
     *         once the clock has run out.
     * @dev With no backers at all the pool goes back to the sponsor. Integer
     *      division dust that cannot be split evenly becomes protocol fees.
     */
    function settleRound(uint256 roundId) external nonReentrant {
        Round storage r = _round(roundId);
        require(block.timestamp >= r.endsAt, "not ended");
        require(!r.settled, "already settled");

        r.settled = true;

        if (r.totalBackers == 0) {
            uint256 refund = r.pool;
            r.pool = 0;
            lockedTotal -= refund;
            emit PoolRefunded(roundId, r.sponsor, refund);
            if (refund > 0) {
                (bool ok, ) = payable(r.sponsor).call{value: refund}("");
                require(ok, "refund failed");
            }
            return;
        }

        uint256[] storage ids = _roundProjects[roundId];
        uint256 distributed;
        for (uint256 i = 0; i < ids.length; i++) {
            Project storage p = _projects[ids[i]];
            if (p.backers == 0) continue;
            uint256 share = (r.pool * p.backers) / r.totalBackers;
            p.matched = share;
            distributed += share;
        }

        uint256 dust = r.pool - distributed;
        if (dust > 0) {
            accumulatedFees += dust;
            lockedTotal -= dust;
        }
        emit RoundSettled(roundId, msg.sender, distributed, dust);
    }

    /// @notice Project owner collects contributions plus match, once, after settlement.
    function claim(uint256 projectId) external nonReentrant {
        Project storage p = _project(projectId);
        Round storage r = _rounds[p.roundId];
        require(r.settled, "not settled");
        require(p.owner == msg.sender, "not project owner");
        require(!p.claimed, "already claimed");

        uint256 gross = p.raised + p.matched;
        require(gross > 0, "nothing to claim");

        p.claimed = true;
        uint256 fee = (gross * feeBps) / 10_000;
        uint256 net = gross - fee;
        accumulatedFees += fee;
        lockedTotal -= gross;

        emit Claimed(projectId, msg.sender, p.raised, p.matched, fee);

        (bool ok, ) = payable(msg.sender).call{value: net}("");
        require(ok, "payout failed");
    }

    // --------------------------------------------------------------- views

    /// @notice What a project would match at today, if the round settled now.
    function estimatedMatch(uint256 projectId) external view returns (uint256) {
        Project storage p = _project(projectId);
        Round storage r = _rounds[p.roundId];
        if (r.settled) return p.matched;
        if (r.totalBackers == 0 || p.backers == 0) return 0;
        return (r.pool * p.backers) / r.totalBackers;
    }

    function roundCount() external view returns (uint256) {
        return _rounds.length;
    }

    function projectCount() external view returns (uint256) {
        return _projects.length;
    }

    function getRound(uint256 roundId) external view returns (Round memory) {
        return _round(roundId);
    }

    function getProject(uint256 projectId) external view returns (Project memory) {
        return _project(projectId);
    }

    function getRoundProjects(uint256 roundId) external view returns (uint256[] memory) {
        return _roundProjects[roundId];
    }

    function getProjectsByOwner(address owner) external view returns (uint256[] memory) {
        return _projectsByOwner[owner];
    }

    function contributionOf(uint256 projectId, address backer) external view returns (uint256) {
        return _contributed[projectId][backer];
    }

    /// @notice Newest-first page of round ids.
    function getRecentRounds(uint256 limit) external view returns (uint256[] memory ids) {
        uint256 n = _rounds.length;
        if (limit > n) limit = n;
        ids = new uint256[](limit);
        for (uint256 i = 0; i < limit; i++) {
            ids[i] = n - 1 - i;
        }
    }

    // --------------------------------------------------------------- admin

    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_FEE_BPS, "fee too high");
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Bounded by `accumulatedFees`. Pools and contributions are unreachable.
    function withdrawFees(address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "bad recipient");
        uint256 amount = accumulatedFees;
        require(amount > 0, "nothing to withdraw");
        accumulatedFees = 0;
        emit FeesWithdrawn(to, amount);
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    // ------------------------------------------------------------ internal

    function _round(uint256 id) private view returns (Round storage) {
        require(id < _rounds.length, "no such round");
        return _rounds[id];
    }

    function _project(uint256 id) private view returns (Project storage) {
        require(id < _projects.length, "no such project");
        return _projects[id];
    }

    receive() external payable {
        accumulatedFees += msg.value;
    }
}
