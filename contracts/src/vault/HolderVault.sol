// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {MerkleProofLib} from "solmate/src/utils/MerkleProofLib.sol";

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title HolderVault
/// @notice Pays $DECOY holders from two streams through one claim.
/// The bite stream is the holders' share of every bite, swept here by the hook in each pool's own
/// currency. It can be distributed as soon as it arrives.
/// The supply stream is $DECOY bought and locked here. Each week releases a fixed share of what is
/// still locked; nothing can unlock it faster.
/// Every week a poster proposes a Merkle root of cumulative amounts per holder and asset, computed
/// from public transfer events. A root pays out only after a delay in which a guardian may veto it,
/// and it can never promise more of an asset than the vault has made distributable. Neither role can
/// move funds. Address zero stands for ETH.
contract HolderVault {
    struct Drip {
        uint256 locked;
        uint64 since;
    }

    struct Pending {
        bytes32 root;
        uint64 readyAt;
        address[] assets;
        uint256[] totals;
    }

    uint256 internal constant WEEK = 7 days;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant ONE = 1e18;

    address public immutable poster;
    address public immutable guardian;
    uint256 public immutable delay;
    /// @notice The share of the locked balance each week releases, in basis points.
    uint256 public immutable dripBps;

    bytes32 public root;
    uint256 public epoch;
    Pending internal pending;
    mapping(address asset => Drip) public drips;
    mapping(address asset => uint256) public committed;
    mapping(address asset => uint256) public paid;
    mapping(address account => mapping(address asset => uint256)) public claimed;

    event Locked(address indexed asset, address indexed by, uint256 amount);
    event Proposed(bytes32 indexed root, uint64 readyAt);
    event Vetoed(bytes32 indexed root);
    event Activated(bytes32 indexed root, uint256 indexed epoch);
    event Claimed(address indexed account, address indexed asset, uint256 amount);

    error NotPoster();
    error NotGuardian();
    error BadConfig();
    error BadRoot();
    error NotReady();
    error OverPromised(address asset);
    error BadProof(address asset);
    error NothingOwed();
    error TransferFailed();

    constructor(address rootPoster, address rootGuardian, uint256 rootDelay, uint256 weeklyDripBps) {
        if (rootPoster == address(0) || rootGuardian == address(0) || rootDelay < 1 hours || weeklyDripBps == 0 || weeklyDripBps > 1_000) {
            revert BadConfig();
        }
        poster = rootPoster;
        guardian = rootGuardian;
        delay = rootDelay;
        dripBps = weeklyDripBps;
    }

    receive() external payable {}

    /// @notice Locks tokens into the supply stream. Irreversible: they leave only through claims.
    function lock(address asset, uint256 amount) external {
        if (asset == address(0) || amount == 0) revert BadConfig();
        Drip storage drip = drips[asset];
        drip.locked = stillLocked(asset) + amount;
        drip.since = uint64(block.timestamp);
        _pull(asset, msg.sender, amount);
        emit Locked(asset, msg.sender, amount);
    }

    /// @notice Proposes the next root: cumulative amounts per holder and asset, with the total of each.
    function propose(bytes32 newRoot, address[] calldata assets, uint256[] calldata totals) external {
        if (msg.sender != poster) revert NotPoster();
        if (newRoot == bytes32(0) || assets.length != totals.length) revert BadRoot();
        for (uint256 i; i < assets.length; i++) {
            if (totals[i] < committed[assets[i]]) revert BadRoot();
            if (totals[i] > distributable(assets[i])) revert OverPromised(assets[i]);
        }
        uint64 readyAt = uint64(block.timestamp + delay);
        pending = Pending(newRoot, readyAt, assets, totals);
        emit Proposed(newRoot, readyAt);
    }

    function veto() external {
        if (msg.sender != guardian) revert NotGuardian();
        bytes32 vetoed = pending.root;
        delete pending;
        emit Vetoed(vetoed);
    }

    /// @notice Makes the pending root the one claims use, once its delay has passed. Anyone may call it.
    function activate() external {
        Pending memory next = pending;
        if (next.root == bytes32(0)) revert BadRoot();
        if (block.timestamp < next.readyAt) revert NotReady();
        for (uint256 i; i < next.assets.length; i++) {
            if (next.totals[i] > distributable(next.assets[i])) revert OverPromised(next.assets[i]);
            committed[next.assets[i]] = next.totals[i];
        }
        root = next.root;
        epoch += 1;
        delete pending;
        emit Activated(next.root, epoch);
    }

    /// @notice Pays an account what the active root says it has earned, less what it already took.
    /// Anyone may call it for anyone; the money only ever goes to the account in the leaf.
    function claim(address account, address[] calldata assets, uint256[] calldata cumulative, bytes32[][] calldata proofs) external {
        if (assets.length != cumulative.length || assets.length != proofs.length) revert BadRoot();
        uint256 total;
        for (uint256 i; i < assets.length; i++) {
            address asset = assets[i];
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, asset, cumulative[i]))));
            if (!MerkleProofLib.verify(proofs[i], root, leaf)) revert BadProof(asset);
            uint256 owed = cumulative[i] - claimed[account][asset];
            if (owed == 0) continue;
            claimed[account][asset] = cumulative[i];
            paid[asset] += owed;
            total += owed;
            _send(asset, account, owed);
            emit Claimed(account, asset, owed);
        }
        if (total == 0) revert NothingOwed();
    }

    /// @notice Everything of an asset the vault has ever been able to pay: paid out, plus held, less
    /// what the supply stream still has locked.
    function distributable(address asset) public view returns (uint256) {
        uint256 held = asset == address(0) ? address(this).balance : IERC20Like(asset).balanceOf(address(this));
        return paid[asset] + held - stillLocked(asset);
    }

    /// @notice What the supply stream still holds back: each whole week since the last lock releases
    /// `dripBps` of the rest.
    function stillLocked(address asset) public view returns (uint256) {
        Drip memory drip = drips[asset];
        if (drip.locked == 0) return 0;
        uint256 weeks_ = (block.timestamp - drip.since) / WEEK;
        return drip.locked * _pow(ONE - dripBps * ONE / BPS, weeks_) / ONE;
    }

    function pendingRoot() external view returns (bytes32 proposed, uint64 readyAt, address[] memory assets, uint256[] memory totals) {
        return (pending.root, pending.readyAt, pending.assets, pending.totals);
    }

    /// @dev x^n for x scaled by 1e18, by squaring.
    function _pow(uint256 x, uint256 n) internal pure returns (uint256 result) {
        result = ONE;
        while (n > 0) {
            if (n & 1 == 1) result = result * x / ONE;
            x = x * x / ONE;
            n >>= 1;
        }
    }

    function _send(address asset, address to, uint256 amount) internal {
        if (asset == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
            return;
        }
        (bool success, bytes memory data) = asset.call(abi.encodeCall(IERC20Like.transfer, (to, amount)));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _pull(address asset, address from, uint256 amount) internal {
        (bool success, bytes memory data) = asset.call(abi.encodeCall(IERC20Like.transferFrom, (from, address(this), amount)));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
