// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ClankRaceV4 — 1-minute bet-triggered races on Robinhood Chain (4663).
/// Gas is only spent when someone bets, claims, or finalizes the week.
/// No cron creates rounds: bet() lazily resolves the previous closed round and
/// opens a fresh one. Empty time burns zero gas.
contract ClankRaceV4 {
    // ---- roles ----
    address public owner;
    address public manager;
    address public deployerTreasury; // recipient of the 2% deployer cut
    address public nft;              // ClankNFT ERC-721

    // ---- config ----
    uint16 public bettingWindowBlocks = 5; // ~1 min at ~0.1s/block (owner-settable)

    // ---- rounds ----
    struct Round {
        uint64 closeBlock;
        uint96 pot;          // sum of 95% of every bet on this round
        uint8  winnerIdx;
        bool   resolved;
        bool   voided;
        bool   swept;
    }
    uint256 public nextRoundId = 1;
    mapping(uint256 => Round) public rounds;
    mapping(uint256 => uint8) public entrantCount;
    mapping(uint256 => mapping(uint8 => uint16)) public entrantAt;   // round -> slot -> clankId
    mapping(uint256 => mapping(uint8 => uint96)) public entrantPot;  // round -> slot -> total bet
    mapping(uint256 => mapping(address => mapping(uint8 => uint96))) public userBet; // round -> better -> slot -> bet
    mapping(uint256 => mapping(address => bool)) public claimedRound;

    // ---- weekly pool + leaderboard ----
    uint256 public weekStartTime;
    uint256 public currentEpoch = 1;
    uint256 public lastFinalizedEpoch; // epoch whose top-3 rewards are currently claimable
    uint96 public weeklyPool;          // 3% cut accumulates here
    uint96 public deployerPending;     // 2% cut accumulates here
    mapping(uint16 => uint32) public wins; // per-epoch wins (reset at finalizeWeek)
    // rewards allocated per (epoch, clankId) — claimable by the clank's holder
    mapping(uint256 => mapping(uint16 => uint96)) public epochClankReward;
    mapping(uint256 => mapping(uint16 => bool)) public epochClankClaimed;

    uint8  constant ENTRANTS = 8;
    uint16 constant CLANK_SUPPLY = 100;
    uint96 constant CUT_BPS = 500;        // 5% total cut of each bet
    uint96 constant DEPLOYER_BPS = 4000;  // 40% of the cut  -> 2% of each bet (deployer)
    uint96 constant WEEK_BPS = 6000;      // 60% of the cut  -> 3% of each bet (weekly pool)
    uint256 constant WEEK = 7 days;

    event Bet(uint256 indexed roundId, uint8 indexed entrantIdx, address indexed better, uint96 amount);
    event Claimed(uint256 indexed roundId, address indexed user, uint96 amount, bool refund);
    event ClankRewardClaimed(uint16 indexed clankId, address indexed from, address indexed to, uint96 amount);
    event DeployerClaimed(address indexed to, uint96 amount);
    event ManagerSet(address indexed manager);
    event TreasurySet(address indexed treasury);
    event RoundCreated(uint256 indexed roundId, uint64 closeBlock, uint16[] entrants);
    event Resolved(uint256 indexed roundId, uint8 winnerIdx, uint16 winnerClank, bool voided, bool swept);
    event WeekFinalized(uint256 indexed epoch, uint16 c1, uint16 c2, uint16 c3, uint96 pool, uint96 r1, uint96 r2, uint96 r3);

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }

    constructor(address _nft, address _treasury) {
        owner = msg.sender;
        manager = msg.sender;
        nft = _nft;
        deployerTreasury = _treasury;
        weekStartTime = block.timestamp;
    }

    // ---- admin ----
    function setManager(address m) external onlyOwner { manager = m; emit ManagerSet(m); }
    function setTreasury(address t) external onlyOwner { deployerTreasury = t; emit TreasurySet(t); }
    function setBettingWindowBlocks(uint16 b) external onlyOwner { require(b >= 1, "too short"); bettingWindowBlocks = b; }
    function transferOwnership(address o) external onlyOwner { owner = o; }

    // ---- round creation ----
    function _pickEntrants() internal view returns (uint16[] memory) {
        uint16[] memory e = new uint16[](ENTRANTS);
        bytes32 seed = keccak256(abi.encodePacked(blockhash(block.number - 1), nextRoundId, block.timestamp));
        uint256 used = 0;
        uint8 count = 0;
        while (count < ENTRANTS) {
            seed = keccak256(abi.encodePacked(seed));
            uint16 id = uint16((uint256(seed) % CLANK_SUPPLY) + 1); // 1..100
            if ((used >> id) & 1 == 0) {
                e[count] = id;
                used |= (uint256(1) << id);
                count++;
            }
        }
        return e;
    }

    function createRound(uint16[] memory entrants) internal returns (uint256 rid) {
        // auto-resolve the previous round if it is closed but not yet resolved
        if (nextRoundId > 1) {
            uint256 prev = nextRoundId - 1;
            if (rounds[prev].closeBlock != 0 && !rounds[prev].resolved && block.number >= rounds[prev].closeBlock) {
                _resolve(prev);
            }
        }
        uint16[] memory e = entrants.length == ENTRANTS ? entrants : _pickEntrants();
        require(e.length == ENTRANTS, "need 8 entrants");
        rid = nextRoundId++;
        rounds[rid].closeBlock = uint64(block.number + bettingWindowBlocks);
        entrantCount[rid] = ENTRANTS;
        for (uint8 i = 0; i < ENTRANTS; i++) {
            entrantAt[rid][i] = e[i];
        }
        emit RoundCreated(rid, rounds[rid].closeBlock, e);
    }

    // ---- betting (gas is only spent here when someone bets) ----
    function bet(uint256 r, uint8 i) external payable {
        // 1) lazily resolve the requested round if its window has closed
        if (rounds[r].closeBlock != 0 && !rounds[r].resolved && block.number >= rounds[r].closeBlock) {
            _resolve(r);
        }
        // 2) if the requested round is resolved (or never existed), open a fresh one and bet on it
        if (rounds[r].resolved || rounds[r].closeBlock == 0) {
            r = createRound(_pickEntrants());
        }
        require(!rounds[r].resolved && !rounds[r].voided, "round closed");
        require(block.number < rounds[r].closeBlock, "betting closed");
        require(i < entrantCount[r], "bad entrant");
        require(msg.value > 0, "no value");

        // 5% cut: 2% deployer, 3% weekly pool. 95% to the round pot.
        uint256 val = msg.value;
        uint256 cut = val * CUT_BPS / 10000;
        uint256 deployerCut = cut * DEPLOYER_BPS / 10000;
        uint256 weekCut = cut - deployerCut;
        uint256 toPot = val - cut;
        deployerPending += uint96(deployerCut);
        weeklyPool += uint96(weekCut);
        rounds[r].pot += uint96(toPot);
        entrantPot[r][i] += uint96(toPot);
        userBet[r][msg.sender][i] += uint96(toPot);
        emit Bet(r, i, msg.sender, uint96(toPot));
    }

    // ---- resolution ----
    function resolve(uint256 r) external {
        require(rounds[r].closeBlock != 0, "no round");
        require(!rounds[r].resolved, "resolved");
        require(block.number >= rounds[r].closeBlock, "not closed");
        _resolve(r);
    }

    function _resolve(uint256 r) internal {
        Round storage rd = rounds[r];
        uint8 cnt = entrantCount[r];
        require(cnt > 0, "no entrants");
        bytes32 bh = blockhash(rd.closeBlock);
        if (bh == 0) bh = blockhash(block.number - 1); // fallback if closeBlock > 256 blocks ago
        if (bh == 0) bh = keccak256(abi.encodePacked(rd.closeBlock, nextRoundId)); // last resort
        uint8 w = uint8(uint256(bh) % cnt);
        rd.winnerIdx = w;
        rd.resolved = true;
        uint16 winClank = entrantAt[r][w];
        if (entrantPot[r][w] == 0) {
            // nobody backed the on-chain winner — orphan pot sweeps to the weekly pool
            rd.swept = true;
            weeklyPool += rd.pot;
        } else {
            wins[winClank] += 1;
        }
        emit Resolved(r, w, winClank, false, rd.swept);
    }

    // ---- claim ----
    function claim(uint256 r) external {
        if (!rounds[r].resolved && rounds[r].closeBlock != 0 && block.number >= rounds[r].closeBlock) {
            _resolve(r);
        }
        require(rounds[r].resolved && !rounds[r].voided, "not resolved");
        require(!claimedRound[r][msg.sender], "already claimed");
        claimedRound[r][msg.sender] = true;
        uint8 w = rounds[r].winnerIdx;
        uint96 myBet = userBet[r][msg.sender][w];
        if (myBet == 0 || entrantPot[r][w] == 0 || rounds[r].swept) {
            emit Claimed(r, msg.sender, 0, false);
            return;
        }
        // proportional share of the full round pot (cut already taken at bet time)
        uint96 payout = uint96(uint256(myBet) * uint256(rounds[r].pot) / uint256(entrantPot[r][w]));
        (bool ok, ) = msg.sender.call{value: payout}("");
        require(ok, "pay failed");
        emit Claimed(r, msg.sender, payout, false);
    }

    // ---- weekly pool / leaderboard ----
    function finalizeWeek() external {
        require(block.timestamp >= weekStartTime + WEEK, "week not over");
        // find top-3 clanks by wins this epoch
        uint16 c1; uint16 c2; uint16 c3;
        uint32 w1; uint32 w2; uint32 w3;
        for (uint16 id = 1; id <= CLANK_SUPPLY; id++) {
            uint32 w = wins[id];
            if (w > w1) { c3 = c2; w3 = w2; c2 = c1; w2 = w1; c1 = id; w1 = w; }
            else if (w > w2) { c3 = c2; w3 = w2; c2 = id; w2 = w; }
            else if (w > w3) { c3 = id; w3 = w; }
        }
        uint96 pool = weeklyPool;
        uint96 r1 = pool * 60 / 100;
        uint96 r2 = pool * 30 / 100;
        uint96 r3 = pool - r1 - r2;
        weeklyPool = 0;
        epochClankReward[currentEpoch][c1] += r1;
        epochClankReward[currentEpoch][c2] += r2;
        epochClankReward[currentEpoch][c3] += r3;
        emit WeekFinalized(currentEpoch, c1, c2, c3, pool, r1, r2, r3);
        lastFinalizedEpoch = currentEpoch;
        currentEpoch += 1;
        weekStartTime = block.timestamp;
        // reset per-epoch wins
        for (uint16 id = 1; id <= CLANK_SUPPLY; id++) wins[id] = 0;
    }

    function clankReward(uint16 clankId) external view returns (uint96) {
        return epochClankReward[lastFinalizedEpoch][clankId];
    }

    function claimClankRewardTo(uint16 clankId, address to) external {
        require(to != address(0), "bad to");
        uint256 epoch = lastFinalizedEpoch;
        require(epoch != 0, "no finalized epoch");
        // caller must currently hold the clank NFT
        (bool ok, bytes memory data) = nft.staticcall(abi.encodeWithSignature("ownerOf(uint256)", uint256(clankId)));
        require(ok && data.length >= 32, "nft err");
        address holder = abi.decode(data, (address));
        require(holder == msg.sender, "not holder");
        uint96 amt = epochClankReward[epoch][clankId];
        require(amt > 0 && !epochClankClaimed[epoch][clankId], "nothing");
        epochClankClaimed[epoch][clankId] = true;
        (bool sent, ) = to.call{value: amt}("");
        require(sent, "send failed");
        emit ClankRewardClaimed(clankId, msg.sender, to, amt);
    }

    function claimDeployer() external {
        uint96 amt = deployerPending;
        require(amt > 0, "nothing");
        deployerPending = 0;
        (bool ok, ) = deployerTreasury.call{value: amt}("");
        require(ok, "send failed");
        emit DeployerClaimed(deployerTreasury, amt);
    }

    // ---- view helpers (ABI compat with V3 frontend) ----
    function entrantBet(uint256 r, uint8 i) external view returns (uint96) { return entrantPot[r][i]; }
    function roundTotalBet(uint256 r) external view returns (uint96) { return rounds[r].pot; }

    receive() external payable {}
}
