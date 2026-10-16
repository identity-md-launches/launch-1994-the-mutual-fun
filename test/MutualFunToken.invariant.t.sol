// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MutualFunToken} from "../src/MutualFunToken.sol";

/// @notice Drives the token with a fixed cast of actors in random order. Every handler keeps ghost
///         copies of what the balances and allowances should be, so the invariants can compare the
///         token's own accounting against an independent one. Success paths move value; failure
///         paths assert the exact revert and that nothing changed.
contract MutualFunTokenHandler is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;

    MutualFunToken public token;
    address public immutable deployer;

    address[] public actors;
    mapping(address => bool) public isActor;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public ghostMoved; // sum of every successful transfer amount
    uint256 public successfulTransfers;
    uint256 public successfulTransferFroms;
    uint256 public rejectedCalls;
    uint256 public unknownSelectorCalls;

    constructor(MutualFunToken token_, address deployer_) {
        token = token_;
        deployer = deployer_;
        _addActor(deployer_);
        _addActor(address(0xA11CE));
        _addActor(address(0xB0B));
        _addActor(address(0xCA201));
        _addActor(address(0xD157)); // stands in for the distributor
        _addActor(address(0x12A7aad083cef06FeF7c295514B52FC8bc81960d)); // remainderTo
        ghostBalance[deployer_] = SUPPLY;
    }

    function _addActor(address a) internal {
        actors.push(a);
        isActor[a] = true;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    // ------------------------------------------------------------------ success paths

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        assertTrue(ok, "transfer returned false");

        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostMoved += amount;
        ++successfulTransfers;
    }

    /// @dev The whole balance in one go: the boundary clamped amounts rarely reach.
    function transferAll(uint256 fromSeed, uint256 toSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = token.balanceOf(from);

        vm.prank(from);
        assertTrue(token.transfer(to, amount), "transfer returned false");
        assertEq(token.balanceOf(from), from == to ? amount : 0, "sender kept something after sending all");

        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostMoved += amount;
        ++successfulTransfers;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        // Spread across the whole range so infinite approvals occur as well as tiny ones.
        if (amount % 7 == 0) amount = type(uint256).max;

        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        ghostAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 cap = allowed < token.balanceOf(owner) ? allowed : token.balanceOf(owner);
        amount = bound(amount, 0, cap);

        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "transferFrom returned false");

        ghostBalance[owner] -= amount;
        ghostBalance[to] += amount;
        ghostMoved += amount;
        if (allowed != type(uint256).max) ghostAllowance[owner][spender] = allowed - amount;
        ++successfulTransferFroms;
    }

    // ------------------------------------------------------------------ failure paths

    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = token.balanceOf(from);
        excess = bound(excess, 1, type(uint256).max - held);
        uint256 amount = held + excess;

        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount));
        token.transfer(to, amount);
        ++rejectedCalls;
    }

    function transferToZeroAddress(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
        ++rejectedCalls;
    }

    function transferFromAboveAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 excess)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == type(uint256).max) return; // nothing is above an infinite allowance
        excess = bound(excess, 1, type(uint256).max - allowed);
        uint256 amount = allowed + excess;

        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
        );
        token.transferFrom(owner, to, amount);
        ++rejectedCalls;
    }

    function transferFromAboveBalanceWithAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 excess) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 held = token.balanceOf(owner);
        excess = bound(excess, 1, type(uint256).max - held);
        uint256 amount = held + excess;

        vm.prank(owner);
        token.approve(spender, type(uint256).max);
        ghostAllowance[owner][spender] = type(uint256).max;

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount));
        token.transferFrom(owner, spender, amount);
        ++rejectedCalls;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), amount);
        ++rejectedCalls;
    }

    /// @dev A stranger with no allowance tries to pull from an actor: the holder's balance is theirs alone.
    function strangerPullsFromHolder(address stranger, uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        if (isActor[stranger] || stranger == address(0)) stranger = address(0x57A9E);
        amount = bound(amount, 1, type(uint256).max);
        assertEq(token.allowance(owner, stranger), 0, "stranger has an allowance it was never given");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount));
        token.transferFrom(owner, stranger, amount);
        ++rejectedCalls;
    }

    function sendEther(uint256 fromSeed, uint256 value) external {
        address from = _actor(fromSeed);
        value = bound(value, 1, 1_000 ether);
        vm.deal(from, value);
        vm.prank(from);
        (bool ok,) = address(token).call{value: value}("");
        assertFalse(ok, "token accepted ether");
        ++rejectedCalls;
    }

    /// @dev Any selector the ABI does not declare, from anyone including the deployer, with any
    ///      arguments: it must not exist, and so must not move anything.
    function unknownSelector(bytes4 selector, uint256 callerSeed, address a, uint256 b) external {
        if (_isDeclared(selector)) return;
        address caller = callerSeed % 3 == 0 ? address(uint160(callerSeed)) : _actor(callerSeed);
        if (caller == address(0)) caller = deployer;

        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodeWithSelector(selector, a, b));
        assertFalse(ok, "an undeclared selector succeeded");
        ++unknownSelectorCalls;
    }

    function _isDeclared(bytes4 s) internal pure returns (bool) {
        return s == IERC20.transfer.selector || s == IERC20.transferFrom.selector || s == IERC20.approve.selector
            || s == IERC20.allowance.selector || s == IERC20.balanceOf.selector || s == IERC20.totalSupply.selector
            || s == bytes4(keccak256("name()")) || s == bytes4(keccak256("symbol()"))
            || s == bytes4(keccak256("decimals()")) || s == bytes4(keccak256("TOKEN_NAME()"))
            || s == bytes4(keccak256("TOKEN_SYMBOL()")) || s == bytes4(keccak256("TOKEN_DECIMALS()"))
            || s == bytes4(keccak256("TOTAL_SUPPLY_TOKENS()")) || s == bytes4(keccak256("TOTAL_SUPPLY()"));
    }
}

/// @notice Invariants that must hold after every random sequence the handler produces.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract MutualFunTokenInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    address constant DEPLOYER = address(0xDE91);

    MutualFunToken token;
    MutualFunTokenHandler handler;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new MutualFunToken();
        handler = new MutualFunTokenHandler(token, DEPLOYER);

        targetContract(address(handler));
        // The actors are pranked; the handler itself never needs to be a sender.
        excludeSender(address(handler));
    }

    /// @dev Fixed supply: no call sequence mints or burns.
    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }

    /// @dev Conservation: what the actors hold sums to the supply, with nothing leaked to the
    ///      zero address, the token itself or the handler.
    function invariant_sumOfBalancesEqualsSupply() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, SUPPLY, "actor balances do not sum to the supply");
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
        assertEq(token.balanceOf(address(token)), 0, "the token holds its own tokens");
        assertEq(token.balanceOf(address(handler)), 0, "the handler holds tokens");
    }

    /// @dev The token's balances agree with the independent ghost accounting.
    function invariant_balancesMatchGhosts() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            assertEq(token.balanceOf(a), handler.ghostBalance(a), "balance diverged from ghost");
            assertLe(token.balanceOf(a), SUPPLY, "a balance exceeds the supply");
        }
    }

    /// @dev Allowances are exactly what was approved, less what was spent, and infinite ones stay infinite.
    function invariant_allowancesMatchGhosts() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender), "allowance diverged");
            }
        }
    }

    /// @dev Nobody ends up with more than entered circulation through them: the deployer's loss
    ///      is at most what moved, and nobody but the deployer can hold more than what moved.
    function invariant_nobodyHoldsMoreThanWasMoved() public view {
        uint256 moved = handler.ghostMoved();
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            if (a == DEPLOYER) {
                assertGe(token.balanceOf(a) + moved, SUPPLY, "deployer lost more than was moved");
            } else {
                assertLe(token.balanceOf(a), moved, "holder has more than was ever moved");
            }
        }
    }

    function invariant_metadataIsImmutable() public view {
        assertEq(token.name(), "The mutual fun");
        assertEq(token.symbol(), "TMF");
        assertEq(token.decimals(), 18);
    }

    function invariant_tokenHoldsNoEther() public view {
        assertEq(address(token).balance, 0);
    }
}
