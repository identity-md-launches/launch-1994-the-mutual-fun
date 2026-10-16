// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MutualFunToken} from "../src/MutualFunToken.sol";
import {DeployMutualFunToken} from "../script/DeployMutualFunToken.s.sol";

/// @notice Stands in for the launch factory: deploys the token's creation code with CREATE2 and
///         holds the minted supply, exactly as the ProjectFactory does at launch.
contract FactoryStandIn {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "constructor failed");
    }

    function move(IERC20 token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract MutualFunTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 constant SWARM_BPS = 1_000;
    uint256 constant POOL_BPS = 8_000;

    address constant DEPLOYER = address(0xDE91);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant DISTRIBUTOR = address(0xD157);
    address constant CLAIMANT = address(0xC1A1);
    address constant REMAINDER_TO = address(0x12A7aad083cef06FeF7c295514B52FC8bc81960d);

    MutualFunToken token;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new MutualFunToken();
    }

    // ---------------------------------------------------------------- metadata and supply

    function test_metadata() public view {
        assertEq(token.name(), "The mutual fun");
        assertEq(token.symbol(), "TMF");
        assertEq(token.decimals(), 18);
    }

    function test_constantsMatchBrief() public view {
        assertEq(token.TOKEN_NAME(), "The mutual fun");
        assertEq(token.TOKEN_SYMBOL(), "TMF");
        assertEq(token.TOKEN_DECIMALS(), 18);
        assertEq(token.TOTAL_SUPPLY_TOKENS(), 1_000_000_000);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000_000_000_000_000_000_000);
    }

    function test_mintsWholeSupplyToDeployerOnce() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_emitsTransferFromZeroOnMint() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), DEPLOYER, SUPPLY);
        vm.prank(DEPLOYER);
        new MutualFunToken();
    }

    /// @dev The launch deploys through the factory with CREATE2; the supply must land on the factory.
    function test_create2DeploymentMintsToTheFactory() public {
        FactoryStandIn factory = new FactoryStandIn();
        bytes memory code = type(MutualFunToken).creationCode;
        bytes32 salt = bytes32(uint256(42));
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(code)))))
        );
        address deployed = factory.deploy(code, salt);
        assertEq(deployed, predicted, "CREATE2 address prediction");
        MutualFunToken launched = MutualFunToken(deployed);
        assertEq(launched.totalSupply(), SUPPLY);
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
    }

    function test_constructorTakesNoArgumentsAndNeedsNoOtherContract() public {
        // Deploying on an otherwise empty chain state from a fresh EOA-like address succeeds.
        address lonely = address(0x10E1);
        assertEq(lonely.code.length, 0);
        vm.prank(lonely);
        MutualFunToken fresh = new MutualFunToken();
        assertEq(fresh.balanceOf(lonely), SUPPLY);
    }

    // ---------------------------------------------------------------- transfers: success

    function test_transferMovesExactAmount() public {
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(ALICE, 1_000e18));
        assertEq(token.balanceOf(ALICE), 1_000e18);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 1_000e18);
        assertEq(token.totalSupply(), SUPPLY, "transfer changed the supply");
    }

    function test_transferEmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(DEPLOYER, ALICE, 5e18);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 5e18);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(DEPLOYER);
        token.transfer(DEPLOYER, 123e18);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }

    function test_transferWholeBalance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, SUPPLY);
        assertEq(token.balanceOf(DEPLOYER), 0);
        assertEq(token.balanceOf(ALICE), SUPPLY);
    }

    // ---------------------------------------------------------------- transfers: failure

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        token.transfer(BOB, 1);
    }

    function test_transferRevertsOneAboveBalance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 10e18);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 10e18, 10e18 + 1));
        token.transfer(BOB, 10e18 + 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    // ---------------------------------------------------------------- allowances

    function test_approveAndTransferFrom() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 100e18);

        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(ALICE, BOB, 60e18);
        vm.prank(ALICE);
        assertTrue(token.approve(BOB, 60e18));
        assertEq(token.allowance(ALICE, BOB), 60e18);

        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, BOB, 40e18));
        assertEq(token.balanceOf(ALICE), 60e18);
        assertEq(token.balanceOf(BOB), 40e18);
        assertEq(token.allowance(ALICE, BOB), 20e18, "allowance not reduced");
    }

    function test_infiniteAllowanceIsNotReduced() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 100e18);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        token.transferFrom(ALICE, BOB, 100e18);
        assertEq(token.allowance(ALICE, BOB), type(uint256).max);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 100e18);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(ALICE, BOB, 1);
    }

    function test_transferFromRevertsAboveAllowance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 100e18);
        vm.prank(ALICE);
        token.approve(BOB, 10e18);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 10e18, 10e18 + 1));
        token.transferFrom(ALICE, BOB, 10e18 + 1);
    }

    function test_transferFromRevertsAboveBalanceEvenWithAllowance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 5e18);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 5e18, 6e18));
        token.transferFrom(ALICE, BOB, 6e18);
    }

    function test_approveZeroSpenderReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ---------------------------------------------------------------- launch flows

    /// @dev The factory moves 10% to the distributor, the distributor pays a claim, 80% is reserved
    ///      for the pool and the rest goes to the requester: every hop arrives whole.
    function test_launchFlowsMoveExactAmounts() public {
        FactoryStandIn factory = new FactoryStandIn();
        MutualFunToken launched = MutualFunToken(factory.deploy(type(MutualFunToken).creationCode, bytes32(0)));

        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        uint256 pool = (SUPPLY * POOL_BPS) / 10_000;
        uint256 remainder = SUPPLY - swarm - pool;

        assertTrue(factory.move(launched, DISTRIBUTOR, swarm));
        assertEq(launched.balanceOf(DISTRIBUTOR), swarm, "swarm share arrived short");

        vm.prank(DISTRIBUTOR);
        assertTrue(launched.transfer(CLAIMANT, swarm));
        assertEq(launched.balanceOf(CLAIMANT), swarm, "claim arrived short");
        assertEq(launched.balanceOf(DISTRIBUTOR), 0);

        assertTrue(factory.move(launched, REMAINDER_TO, remainder));
        assertEq(launched.balanceOf(REMAINDER_TO), remainder, "remainder arrived short");
        assertEq(launched.balanceOf(address(factory)), pool, "pool share is not what is left");
        assertEq(launched.totalSupply(), SUPPLY, "launch flows changed the supply");
    }

    // ---------------------------------------------------------------- no admin surface

    function test_noMintOrAdminSelectorExists() public {
        string[16] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "owner()",
            "setOwner(address)",
            "transferOwnership(address)",
            "renounceOwnership()",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)",
            "blacklist(address)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, type(uint128).max);
            vm.prank(DEPLOYER);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(ALICE), 0, signatures[i]);
        }
    }

    function test_deployerCannotMoveAHoldersBalance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 1_000e18);
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, DEPLOYER, 0, 1));
        token.transferFrom(ALICE, DEPLOYER, 1);
        assertEq(token.balanceOf(ALICE), 1_000e18);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 500e18));
        assertEq(token.balanceOf(BOB), 500e18);
    }

    function test_noEtherAccepted() public {
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "token accepted ether");
        assertEq(address(token).balance, 0);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != DEPLOYER);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(to) + token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 held, uint256 excess) public {
        held = bound(held, 0, SUPPLY - 1);
        excess = bound(excess, 1, SUPPLY - held);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, held);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, held, held + excess)
        );
        token.transfer(BOB, held + excess);
    }

    function testFuzz_transferFromWithinAllowance(uint256 allowance_, uint256 amount) public {
        allowance_ = bound(allowance_, 0, SUPPLY);
        amount = bound(amount, 0, allowance_);
        vm.prank(DEPLOYER);
        token.approve(BOB, allowance_);
        vm.prank(BOB);
        assertTrue(token.transferFrom(DEPLOYER, ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.allowance(DEPLOYER, BOB), allowance_ - amount);
    }

    function testFuzz_randomCallCannotGrowSupply(bytes4 selector, address caller, uint256 arg) public {
        bytes memory data = abi.encodeWithSelector(selector, caller, arg);
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        ok;
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------- script

    function test_deployScriptFunctionMintsToCaller() public {
        DeployMutualFunToken deployer = new DeployMutualFunToken();
        MutualFunToken deployed = deployer.deploy();
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(deployer)), SUPPLY);
        assertEq(deployed.name(), "The mutual fun");
        assertEq(deployed.symbol(), "TMF");
    }
}
