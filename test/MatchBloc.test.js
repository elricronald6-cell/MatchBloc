const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const DAY = 86400;
const E = (n) => ethers.parseEther(String(n));

describe("MatchBloc", function () {
  let mb, owner, sponsor, alice, bob, carol, dave;

  beforeEach(async () => {
    [owner, sponsor, alice, bob, carol, dave] = await ethers.getSigners();
    const F = await ethers.getContractFactory("MatchBloc");
    mb = await F.deploy();
    await mb.waitForDeployment();
  });

  async function newRound(pool = "10", dur = 7 * DAY) {
    await mb.connect(sponsor).createRound("Autumn ecosystem round", dur, { value: E(pool) });
    return (await mb.roundCount()) - 1n;
  }
  async function register(roundId, who, name) {
    await mb.connect(who).registerProject(roundId, name);
    return (await mb.projectCount()) - 1n;
  }

  it("creates a round with a seeded pool", async () => {
    const id = await newRound();
    const r = await mb.getRound(id);
    expect(r.sponsor).to.equal(sponsor.address);
    expect(r.pool).to.equal(E(10));
    expect(r.settled).to.equal(false);
    expect(await mb.lockedTotal()).to.equal(E(10));
  });

  it("rejects a dust pool, a bad name and a bad duration", async () => {
    await expect(mb.connect(sponsor).createRound("x", 7 * DAY, { value: 1 })).to.be.revertedWith("pool too small");
    await expect(mb.connect(sponsor).createRound("", 7 * DAY, { value: E(1) })).to.be.revertedWith("bad name");
    await expect(mb.connect(sponsor).createRound("x", 600, { value: E(1) })).to.be.revertedWith("bad duration");
    await expect(mb.connect(sponsor).createRound("x", 200 * DAY, { value: E(1) })).to.be.revertedWith("bad duration");
  });

  it("registers projects until the round closes", async () => {
    const r = await newRound();
    const p = await register(r, alice, "Lightfoot");
    expect((await mb.getProject(p)).owner).to.equal(alice.address);
    expect((await mb.getRound(r)).projectCount).to.equal(1);

    await time.increase(8 * DAY);
    await expect(mb.connect(bob).registerProject(r, "Too late")).to.be.revertedWith("round closed");
  });

  it("counts each backer once however many times they give", async () => {
    const r = await newRound();
    const p = await register(r, alice, "Lightfoot");

    await mb.connect(bob).back(p, { value: E(1) });
    await mb.connect(bob).back(p, { value: E(2) });

    const proj = await mb.getProject(p);
    expect(proj.raised).to.equal(E(3));
    expect(proj.backers).to.equal(1);
    expect((await mb.getRound(r)).totalBackers).to.equal(1);
    expect(await mb.contributionOf(p, bob.address)).to.equal(E(3));
  });

  it("stops a project owner backing their own project", async () => {
    const r = await newRound();
    const p = await register(r, alice, "Lightfoot");
    await expect(mb.connect(alice).back(p, { value: E(1) })).to.be.revertedWith("owner cannot back");
  });

  it("splits the pool by backer count, not by amount given", async () => {
    const r = await newRound("10");
    const a = await register(r, alice, "Lightfoot");
    const b = await register(r, bob, "Quarry");

    // Three small backers for A, one large backer for B.
    await mb.connect(carol).back(a, { value: E("0.1") });
    await mb.connect(dave).back(a, { value: E("0.1") });
    await mb.connect(owner).back(a, { value: E("0.1") });
    await mb.connect(carol).back(b, { value: E(5) });

    expect(await mb.estimatedMatch(a)).to.equal(E("7.5"));
    expect(await mb.estimatedMatch(b)).to.equal(E("2.5"));

    await time.increase(8 * DAY);
    await mb.connect(dave).settleRound(r); // permissionless

    expect((await mb.getProject(a)).matched).to.equal(E("7.5"));
    expect((await mb.getProject(b)).matched).to.equal(E("2.5"));
  });

  it("refuses to settle early and refuses to settle twice", async () => {
    const r = await newRound();
    const p = await register(r, alice, "Lightfoot");
    await mb.connect(bob).back(p, { value: E(1) });

    await expect(mb.connect(bob).settleRound(r)).to.be.revertedWith("not ended");
    await time.increase(8 * DAY);
    await mb.connect(bob).settleRound(r);
    await expect(mb.connect(bob).settleRound(r)).to.be.revertedWith("already settled");
  });

  it("pays raised plus match on claim, minus one fee, once", async () => {
    const r = await newRound("10");
    const p = await register(r, alice, "Lightfoot");
    await mb.connect(bob).back(p, { value: E(2) });

    await time.increase(8 * DAY);
    await mb.connect(bob).settleRound(r);

    // 2 raised + 10 matched = 12 gross, 2.5% fee = 0.3
    await expect(mb.connect(bob).claim(p)).to.be.revertedWith("not project owner");
    await expect(mb.connect(alice).claim(p)).to.changeEtherBalance(alice, E("11.7"));
    expect(await mb.accumulatedFees()).to.equal(E("0.3"));
    await expect(mb.connect(alice).claim(p)).to.be.revertedWith("already claimed");
    expect(await mb.lockedTotal()).to.equal(0);
  });

  it("will not let a project claim before settlement", async () => {
    const r = await newRound();
    const p = await register(r, alice, "Lightfoot");
    await mb.connect(bob).back(p, { value: E(1) });
    await expect(mb.connect(alice).claim(p)).to.be.revertedWith("not settled");
  });

  it("returns the whole pool to the sponsor when nobody backs anything", async () => {
    const r = await newRound("10");
    await register(r, alice, "Lightfoot");
    await time.increase(8 * DAY);

    await expect(mb.connect(dave).settleRound(r)).to.changeEtherBalance(sponsor, E(10));
    expect(await mb.lockedTotal()).to.equal(0);
    expect(await mb.accumulatedFees()).to.equal(0);
  });

  it("sends integer-division dust to fees rather than stranding it", async () => {
    const r = await newRound("10");
    const a = await register(r, alice, "Lightfoot");
    const b = await register(r, bob, "Quarry");
    const c = await register(r, carol, "Meridian");

    await mb.connect(dave).back(a, { value: E("0.1") });
    await mb.connect(owner).back(b, { value: E("0.1") });
    await mb.connect(sponsor).back(c, { value: E("0.1") });

    await time.increase(8 * DAY);
    await mb.connect(dave).settleRound(r);

    const sum = (await mb.getProject(a)).matched + (await mb.getProject(b)).matched + (await mb.getProject(c)).matched;
    expect(sum + (await mb.accumulatedFees())).to.equal(E(10));
    expect(await mb.accumulatedFees()).to.equal(1n); // 10e18 / 3 leaves 1 wei
  });

  it("stops backing once a round has closed", async () => {
    const r = await newRound();
    const p = await register(r, alice, "Lightfoot");
    await time.increase(8 * DAY);
    await expect(mb.connect(bob).back(p, { value: E(1) })).to.be.revertedWith("round closed");
  });

  it("pauses new rounds, registrations and backing", async () => {
    const r = await newRound();
    const p = await register(r, alice, "Lightfoot");
    await mb.connect(owner).pause();

    await expect(mb.connect(bob).back(p, { value: E(1) })).to.be.revertedWithCustomError(mb, "EnforcedPause");
    await expect(mb.connect(bob).registerProject(r, "nope")).to.be.revertedWithCustomError(mb, "EnforcedPause");
    await expect(mb.connect(sponsor).createRound("x", 7 * DAY, { value: E(1) })).to.be.revertedWithCustomError(
      mb,
      "EnforcedPause"
    );
  });

  it("caps the fee and withdraws only fees, owner only", async () => {
    await expect(mb.connect(owner).setFeeBps(900)).to.be.revertedWith("fee too high");

    const r = await newRound("10");
    const p = await register(r, alice, "Lightfoot");
    await mb.connect(bob).back(p, { value: E(2) });
    await time.increase(8 * DAY);
    await mb.connect(bob).settleRound(r);
    await mb.connect(alice).claim(p);

    await expect(mb.connect(bob).withdrawFees(bob.address)).to.be.revertedWithCustomError(
      mb,
      "OwnableUnauthorizedAccount"
    );
    await expect(mb.connect(owner).withdrawFees(owner.address)).to.changeEtherBalance(owner, E("0.3"));
    expect(await ethers.provider.getBalance(await mb.getAddress())).to.equal(0);
  });

  it("indexes projects per round and lists rounds newest first", async () => {
    const r1 = await newRound();
    const a = await register(r1, alice, "Lightfoot");
    const b = await register(r1, bob, "Quarry");
    await newRound();

    expect((await mb.getRoundProjects(r1)).map(Number)).to.deep.equal([Number(a), Number(b)]);
    expect((await mb.getRecentRounds(2)).map(Number)).to.deep.equal([1, 0]);
    expect((await mb.getProjectsByOwner(alice.address)).map(Number)).to.deep.equal([Number(a)]);
  });
});
