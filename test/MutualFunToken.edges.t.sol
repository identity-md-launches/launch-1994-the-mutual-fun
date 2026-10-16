// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MutualFunToken} from "../src/MutualFunToken.sol";

/// @notice Edge inputs the main suite does not pin: the same call twice, the zero address as a
///         sender, a spender pulling from itself, allowances one below infinity, approval
///         overwrites, and arithmetic at the top of the range.
/// forge-config: default.fuzz.runs = 1000
contract MutualFunTokenEdgesTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;

    address constant DEPLOYER = address(0xDE91);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA201);

    MutualFunToken token;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new MutualFunToken();
    }

    // ---------------------------------------------------------------- deployment edges

    function test_twoDeploymentsAreIndependent() public {
        vm.prank(ALICE);
        MutualFunToken second = new MutualFunToken();
        assertEq(second.totalSupply(), SUPPLY);
        assertEq(second.balanceOf(ALICE), SUPPLY);
        assertEq(second.balanceOf(DEPLOYER), 0);
        assertEq(token.balanceOf(ALICE), 0, "a second deployment touched the first");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_supplyFitsComfortablyInUint256() public view {
        // 1e27 leaves room: even every holder summed cannot overflow, and the OZ cap check is not hit.
        assertLt(token.totalSupply(), type(uint128).max);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_deployerIsTheOnlyHolderAfterConstruction() public view {
        assertEq(token.balanceOf(DEPLOYER), token.totalSupply());
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }

    // ---------------------------------------------------------------- the same call twice

    function test_sameTransferTwiceMovesTwice() public {
        vm.startPrank(DEPLOYER);
        token.transfer(ALICE, 7e18);
        token.transfer(ALICE, 7e18);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), 14e18);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 14e18);
    }

    function test_sameApproveTwiceOverwritesNotAccumulates() public {
        vm.startPrank(DEPLOYER);
        token.approve(BOB, 10e18);
        token.approve(BOB, 10e18);
        vm.stopPrank();
        assertEq(token.allowance(DEPLOYER, BOB), 10e18, "approve accumulated");
    }

    function test_approveLowerOverwritesHigher() public {
        vm.startPrank(DEPLOYER);
        token.approve(BOB, type(uint256).max);
        token.approve(BOB, 1);
        vm.stopPrank();
        assertEq(token.allowance(DEPLOYER, BOB), 1);
    }

    function test_approveZeroRevokes() public {
        vm.startPrank(DEPLOYER);
        token.approve(BOB, 100e18);
        token.approve(BOB, 0);
        vm.stopPrank();
        assertEq(token.allowance(DEPLOYER, BOB), 0);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(DEPLOYER, BOB, 1);
    }

    function test_spendingWholeAllowanceLeavesZeroAndSecondPullFails() public {
        vm.prank(DEPLOYER);
        token.approve(BOB, 10e18);
        vm.startPrank(BOB);
        token.transferFrom(DEPLOYER, BOB, 10e18);
        assertEq(token.allowance(DEPLOYER, BOB), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(DEPLOYER, BOB, 1);
        vm.stopPrank();
    }

    function test_sameTransferFromTwiceWithinAllowance() public {
        vm.prank(DEPLOYER);
        token.approve(BOB, 10e18);
        vm.startPrank(BOB);
        token.transferFrom(DEPLOYER, CAROL, 5e18);
        token.transferFrom(DEPLOYER, CAROL, 5e18);
        vm.stopPrank();
        assertEq(token.balanceOf(CAROL), 10e18);
        assertEq(token.allowance(DEPLOYER, BOB), 0);
    }

    // ---------------------------------------------------------------- allowance edges

    function test_allowanceOneBelowInfinityIsDecremented() public {
        uint256 almost = type(uint256).max - 1;
        vm.prank(DEPLOYER);
        token.approve(BOB, almost);
        vm.prank(BOB);
        token.transferFrom(DEPLOYER, CAROL, 1e18);
        assertEq(token.allowance(DEPLOYER, BOB), almost - 1e18, "near-infinite allowance was treated as infinite");
    }

    function test_infiniteAllowanceEmitsNoApprovalOnSpend() public {
        vm.prank(DEPLOYER);
        token.approve(BOB, type(uint256).max);
        vm.recordLogs();
        vm.prank(BOB);
        token.transferFrom(DEPLOYER, CAROL, 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "expected exactly one log (Transfer)");
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
    }

    function test_finiteAllowanceSpendEmitsNoApprovalEvent() public {
        // OZ v5 decrements silently (emitEvent = false): the allowance view is the source of truth.
        vm.prank(DEPLOYER);
        token.approve(BOB, 10e18);
        vm.recordLogs();
        vm.prank(BOB);
        token.transferFrom(DEPLOYER, CAROL, 4e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IERC20.Approval.selector, "unexpected Approval on spend");
        }
        assertEq(token.allowance(DEPLOYER, BOB), 6e18);
    }

    function test_transferFromRequiresAllowanceEvenFromSelf() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 10e18);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1e18));
        token.transferFrom(ALICE, BOB, 1e18);
    }

    function test_selfApprovalAllowsSelfTransferFrom() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 10e18);
        vm.startPrank(ALICE);
        token.approve(ALICE, 3e18);
        token.transferFrom(ALICE, BOB, 3e18);
        vm.stopPrank();
        assertEq(token.balanceOf(BOB), 3e18);
        assertEq(token.allowance(ALICE, ALICE), 0);
    }

    function test_transferFromToOwnerKeepsBalanceSpendsAllowance() public {
        vm.prank(DEPLOYER);
        token.approve(BOB, 5e18);
        vm.prank(BOB);
        token.transferFrom(DEPLOYER, DEPLOYER, 5e18);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.allowance(DEPLOYER, BOB), 0);
    }

    function test_transferFromZeroAmountWithoutAllowanceSucceeds() public {
        vm.prank(BOB);
        assertTrue(token.transferFrom(DEPLOYER, CAROL, 0));
        assertEq(token.balanceOf(CAROL), 0);
    }

    function test_transferFromToZeroAddressReverts() public {
        vm.prank(DEPLOYER);
        token.approve(BOB, 1e18);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(DEPLOYER, address(0), 1e18);
    }

    function test_allowanceDoesNotFollowTokensToANewHolder() public {
        vm.prank(DEPLOYER);
        token.approve(BOB, 100e18);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 100e18);
        assertEq(token.allowance(ALICE, BOB), 0, "allowance leaked to the recipient");
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(ALICE, BOB, 1);
    }

    // ---------------------------------------------------------------- zero address as a sender

    function test_zeroAddressCannotSend() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        token.transfer(ALICE, 0);
    }

    function test_zeroAddressCannotApprove() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.approve(ALICE, 1);
    }

    function test_nobodyCanPullFromTheZeroAddress() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        token.transferFrom(address(0), ALICE, 1);
    }

    // ---------------------------------------------------------------- range edges

    function test_transferMaxUint256Reverts() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DEPLOYER, SUPPLY, type(uint256).max)
        );
        token.transfer(ALICE, type(uint256).max);
    }

    function test_transferSupplyPlusOneReverts() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DEPLOYER, SUPPLY, SUPPLY + 1)
        );
        token.transfer(ALICE, SUPPLY + 1);
    }

    function test_oneWeiTransferRoundTrip() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 1);
        vm.prank(ALICE);
        token.transfer(DEPLOYER, 1);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function test_tokensSentToTheContractItselfAreStuck() public {
        // There is no admin to recover them: document that this is a one-way door.
        vm.prank(DEPLOYER);
        token.transfer(address(token), 1e18);
        assertEq(token.balanceOf(address(token)), 1e18);
        assertEq(token.totalSupply(), SUPPLY);
        vm.prank(address(token));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(token), 0, 1));
        token.transferFrom(address(token), DEPLOYER, 1);
    }

    function test_constantsAreNotSettable() public {
        string[4] memory sigs =
            ["TOKEN_NAME(string)", "TOKEN_SYMBOL(string)", "TOTAL_SUPPLY(uint256)", "setDecimals(uint8)"];
        for (uint256 i; i < sigs.length; ++i) {
            vm.prank(DEPLOYER);
            (bool ok,) = address(token).call(abi.encodeWithSignature(sigs[i], uint256(1)));
            assertFalse(ok, sigs[i]);
        }
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------- fuzz properties

    /// @dev Round trip: sending and sending back restores both balances exactly.
    function testFuzz_transferRoundTripRestoresBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, amount);
        vm.prank(ALICE);
        token.transfer(DEPLOYER, amount);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }

    /// @dev Splitting a transfer into two parts arrives at the same state as one transfer.
    function testFuzz_transferIsAdditive(uint256 a, uint256 b) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);
        vm.startPrank(DEPLOYER);
        token.transfer(ALICE, a);
        token.transfer(ALICE, b);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), a + b);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - a - b);
    }

    /// @dev A transfer between two third parties never touches anyone else's balance.
    function testFuzz_transferDoesNotTouchBystanders(uint256 funded, uint256 moved) public {
        funded = bound(funded, 0, SUPPLY / 2);
        moved = bound(moved, 0, funded);
        vm.startPrank(DEPLOYER);
        token.transfer(ALICE, funded);
        token.transfer(CAROL, funded);
        vm.stopPrank();
        uint256 deployerBefore = token.balanceOf(DEPLOYER);
        vm.prank(ALICE);
        token.transfer(BOB, moved);
        assertEq(token.balanceOf(CAROL), funded, "bystander balance changed");
        assertEq(token.balanceOf(DEPLOYER), deployerBefore, "deployer balance changed");
        assertEq(token.balanceOf(ALICE) + token.balanceOf(BOB), funded);
    }

    /// @dev Approval is idempotent in the last value: the allowance is the last approve, whatever came before.
    function testFuzz_lastApproveWins(uint256 first, uint256 second) public {
        vm.startPrank(DEPLOYER);
        token.approve(BOB, first);
        token.approve(BOB, second);
        vm.stopPrank();
        assertEq(token.allowance(DEPLOYER, BOB), second);
    }

    /// @dev Allowances are per (owner, spender): approving one spender grants nothing to another.
    function testFuzz_allowanceIsPerSpender(uint256 amount) public {
        vm.prank(DEPLOYER);
        token.approve(BOB, amount);
        assertEq(token.allowance(DEPLOYER, CAROL), 0);
        assertEq(token.allowance(BOB, DEPLOYER), 0);
        assertEq(token.allowance(DEPLOYER, BOB), amount);
    }

    /// @dev One above the allowance always reverts with the exact error, for any finite allowance.
    function testFuzz_transferFromOneAboveAllowanceReverts(uint256 allowance_) public {
        allowance_ = bound(allowance_, 0, SUPPLY - 1);
        vm.prank(DEPLOYER);
        token.approve(BOB, allowance_);
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, allowance_, allowance_ + 1)
        );
        token.transferFrom(DEPLOYER, CAROL, allowance_ + 1);
        assertEq(token.allowance(DEPLOYER, BOB), allowance_, "a failed pull changed the allowance");
        assertEq(token.balanceOf(CAROL), 0);
    }

    /// @dev Any caller, any amount: without an allowance nothing leaves a holder.
    function testFuzz_strangerCannotPull(address stranger, uint256 amount) public {
        amount = bound(amount, 1, type(uint256).max);
        vm.assume(stranger != address(0));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount));
        token.transferFrom(DEPLOYER, stranger, amount);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }

    /// @dev Any recipient but the zero address can receive, and receives exactly the amount.
    function testFuzz_anyNonZeroRecipientReceivesExactly(address to, uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        if (to == address(0)) to = ALICE;
        uint256 before = token.balanceOf(to);
        vm.prank(DEPLOYER);
        token.transfer(to, amount);
        if (to == DEPLOYER) {
            assertEq(token.balanceOf(to), SUPPLY);
        } else {
            assertEq(token.balanceOf(to) - before, amount);
            assertEq(token.balanceOf(DEPLOYER), SUPPLY - amount);
        }
    }

    /// @dev Calling with calldata shorter than a full ABI encoding reverts rather than misreading it.
    function testFuzz_shortCalldataReverts(uint8 length) public {
        length = uint8(bound(length, 4, 67)); // full transfer(address,uint256) is 68 bytes
        bytes memory full = abi.encodeWithSelector(IERC20.transfer.selector, ALICE, uint256(1e18));
        bytes memory short = new bytes(length);
        for (uint256 i; i < length; ++i) {
            short[i] = full[i];
        }
        vm.prank(DEPLOYER);
        (bool ok,) = address(token).call(short);
        assertFalse(ok, "short calldata was accepted");
        assertEq(token.balanceOf(ALICE), 0);
    }
}
