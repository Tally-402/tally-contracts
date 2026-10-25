// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {TabManager} from "../src/TabManager.sol";
import {Escrow} from "../src/Escrow.sol";
import {ITabManager} from "../src/interfaces/ITally.sol";
import {MockUSDC} from "./mocks/Mocks.sol";

/// @dev Drives random sequences of real user actions across several lines.
contract Handler is Test {
    MockUSDC public usdc;
    CreditPool public pool;
    TabManager public tabs;
    Escrow public escrow;
    address public verifier;
    address public arbiter;

    uint256[] public lineIds;
    mapping(uint256 => uint256) public agentPkOf;
    mapping(uint256 => address) public ownerOf;
    uint256[] public holdIds;
    uint256 public nonce;
    uint256 public paysOk;
    uint256 public repaysOk;
    uint256 public liquidationsOk;
    address public seller = makeAddr("h_seller");
    address public network = makeAddr("h_network");
    uint256 public sponsorId;

    constructor(MockUSDC u, CreditPool p, TabManager t, Escrow e, address v, address a) {
        usdc = u;
        pool = p;
        tabs = t;
        escrow = e;
        verifier = v;
        arbiter = a;
        for (uint256 i = 0; i < 3; i++) {
            address o = makeAddr(string(abi.encodePacked("h_owner", i)));
            uint256 pk = 0x1000 + i;
            usdc.mint(o, 1e15);
            vm.startPrank(o);
            usdc.approve(address(tabs), type(uint256).max);
            uint256 id = tabs.openLine(vm.addr(pk));
            tabs.depositCollateral(id, 5_000e6);
            tabs.setMandate(id, uint128(2_000e6), type(uint128).max, type(uint64).max, bytes32(0));
            vm.stopPrank();
            lineIds.push(id);
            agentPkOf[id] = pk;
            ownerOf[id] = o;
        }
        // A network sponsors two more agents from one deposit; one line has its own cap.
        usdc.mint(network, 1e15);
        vm.startPrank(network);
        usdc.approve(address(tabs), type(uint256).max);
        sponsorId = tabs.openSponsor();
        tabs.depositSponsorCollateral(sponsorId, 3_000e6);
        for (uint256 i = 0; i < 2; i++) {
            uint256 pk = 0x2000 + i;
            uint256 id = tabs.openSponsoredLine(sponsorId, vm.addr(pk), i == 0 ? tabs.NO_CAP() : uint128(1_000e6));
            tabs.setMandate(id, uint128(2_000e6), type(uint128).max, type(uint64).max, bytes32(0));
            lineIds.push(id);
            agentPkOf[id] = pk;
            ownerOf[id] = network;
        }
        vm.stopPrank();
    }

    function sponsorDeposit(uint256 amount) external {
        amount = bound(amount, 1, 2_000e6);
        vm.prank(network);
        tabs.depositSponsorCollateral(sponsorId, amount);
    }

    function sponsorWithdraw(uint256 amount) external {
        amount = bound(amount, 0, tabs.sponsorFreeCollateral(sponsorId));
        vm.prank(network);
        try tabs.withdrawSponsorCollateral(sponsorId, amount, network) {} catch {}
    }

    function lineCount() external view returns (uint256) {
        return lineIds.length;
    }

    function holdCount() external view returns (uint256) {
        return holdIds.length;
    }

    function pay(uint256 lineSeed, uint256 amount, bool escrowed) external {
        uint256 id = lineIds[lineSeed % lineIds.length];
        amount = bound(amount, 1, 400e6);
        TabManager.PaymentIntent memory p = TabManager.PaymentIntent({
            lineId: id,
            epoch: tabs.getLine(id).epoch,
            seller: seller,
            amount: amount,
            resource: bytes32(nonce),
            escrowed: escrowed,
            nonce: ++nonce,
            deadline: vm.getBlockTimestamp() + 1 hours
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentPkOf[id], tabs.hashIntent(p));
        try tabs.pay(p, abi.encodePacked(r, s, v), new bytes32[](0)) returns (uint256 holdId) {
            paysOk++;
            if (holdId != 0) holdIds.push(holdId);
        } catch {}
    }

    function repay(uint256 lineSeed, uint256 amount) external {
        uint256 id = lineIds[lineSeed % lineIds.length];
        amount = bound(amount, 1, 5_000e6);
        vm.prank(ownerOf[id]);
        try tabs.repay(id, amount) {
            repaysOk++;
        } catch {}
    }

    function depositCollateral(uint256 lineSeed, uint256 amount) external {
        uint256 id = lineIds[lineSeed % lineIds.length];
        amount = bound(amount, 1, 5_000e6);
        if (tabs.sponsorOf(id) != 0) return;
        vm.prank(ownerOf[id]);
        tabs.depositCollateral(id, amount);
    }

    function withdrawCollateral(uint256 lineSeed, uint256 amount) external {
        uint256 id = lineIds[lineSeed % lineIds.length];
        amount = bound(amount, 0, tabs.freeCollateral(id));
        vm.prank(ownerOf[id]);
        try tabs.withdrawCollateral(id, amount, ownerOf[id]) {} catch {}
    }

    function warp(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 10 minutes, 3 days));
    }

    function liquidate(uint256 lineSeed) external {
        try tabs.liquidate(lineIds[lineSeed % lineIds.length]) {
            liquidationsOk++;
        } catch {}
    }

    function escrowAction(uint256 holdSeed, uint8 action) external {
        if (holdIds.length == 0) return;
        uint256 h = holdIds[holdSeed % holdIds.length];
        action = action % 5;
        if (action == 0) {
            vm.prank(verifier);
            try escrow.pass(h) {} catch {}
        } else if (action == 1) {
            vm.prank(verifier);
            try escrow.flag(h, bytes32(0)) {} catch {}
        } else if (action == 2) {
            try escrow.claim(h) {} catch {}
        } else if (action == 3) {
            vm.prank(arbiter);
            try escrow.resolve(h, holdSeed % 2 == 0) {} catch {}
        } else {
            try escrow.expire(h) {} catch {}
        }
    }
}

contract InvariantsTest is Test {
    MockUSDC usdc;
    CreditPool pool;
    TabManager tabs;
    Escrow escrow;
    Handler handler;

    function setUp() public {
        address admin = makeAddr("admin");
        address verifier = makeAddr("verifier");
        address arbiter = makeAddr("arbiter");
        usdc = new MockUSDC();
        pool = new CreditPool(usdc, admin, 0);
        tabs = new TabManager(usdc, pool, admin, makeAddr("treasury"));
        escrow = new Escrow(usdc, ITabManager(address(tabs)), admin);
        vm.startPrank(admin);
        pool.grantRole(pool.MANAGER_ROLE(), address(tabs));
        tabs.setEscrow(address(escrow));
        escrow.grantRole(escrow.VERIFIER_ROLE(), verifier);
        escrow.grantRole(escrow.ARBITER_ROLE(), arbiter);
        vm.stopPrank();

        address lp = makeAddr("lp");
        usdc.mint(lp, 50_000e6);
        vm.startPrank(lp);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(50_000e6, lp);
        vm.stopPrank();

        handler = new Handler(usdc, pool, tabs, escrow, verifier, arbiter);
        targetContract(address(handler));
    }

    function afterInvariant() external view {
        console.log("pays", handler.paysOk(), "holds", handler.holdCount());
        console.log("repays", handler.repaysOk(), "liquidations", handler.liquidationsOk());
    }

    /// The pool's books equal the sum of every line's balance.
    function invariant_PoolOutstandingMatchesLines() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.lineCount(); i++) {
            sum += tabs.outstandingOf(handler.lineIds(i));
        }
        assertEq(pool.outstanding(), sum);
    }

    /// Every tab is fully secured: own-collateral lines by their collateral, sponsored lines by the sponsor's.
    function invariant_TabsNeverExceedCollateral() public view {
        for (uint256 i = 0; i < handler.lineCount(); i++) {
            uint256 id = handler.lineIds(i);
            if (tabs.sponsorOf(id) == 0) assertLe(tabs.outstandingOf(id), tabs.getLine(id).collateral);
        }
        TabManager.Sponsor memory s = tabs.getSponsor(handler.sponsorId());
        assertLe(s.outstanding, s.collateral);
    }

    /// The sponsor's running total equals the sum of its lines' balances.
    function invariant_SponsorTotalMatchesLines() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.lineCount(); i++) {
            uint256 id = handler.lineIds(i);
            if (tabs.sponsorOf(id) == handler.sponsorId()) sum += tabs.outstandingOf(id);
        }
        assertEq(tabs.getSponsor(handler.sponsorId()).outstanding, sum);
    }

    /// The TabManager holds exactly the posted collateral, nothing more or less.
    function invariant_ManagerHoldsOnlyCollateral() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.lineCount(); i++) {
            sum += tabs.getLine(handler.lineIds(i)).collateral;
        }
        sum += tabs.getSponsor(handler.sponsorId()).collateral;
        assertEq(usdc.balanceOf(address(tabs)), sum + tabs.feesAccrued() + tabs.voucherFeesTotal());
    }

    /// Escrow holds exactly the open (held or flagged) amounts.
    function invariant_EscrowHoldsOpenAmounts() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.holdCount(); i++) {
            (,,,, Escrow.Status st, uint128 amount,,) = escrow.holds(handler.holdIds(i));
            if (st == Escrow.Status.Held || st == Escrow.Status.Flagged) sum += amount;
        }
        assertEq(usdc.balanceOf(address(escrow)), sum);
    }

    /// Secured lending never loses depositor money: pool assets never fall below deposits.
    function invariant_DepositorsNeverLose() public view {
        assertGe(pool.totalAssets(), 50_000e6);
    }
}
