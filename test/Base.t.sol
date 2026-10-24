// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {TabManager} from "../src/TabManager.sol";
import {Escrow} from "../src/Escrow.sol";
import {ITabManager} from "../src/interfaces/ITally.sol";
import {MockUSDC} from "./mocks/Mocks.sol";

abstract contract BaseTest is Test {
    uint256 internal constant USDC = 1e6;

    MockUSDC internal usdc;
    CreditPool internal pool;
    TabManager internal tabs;
    Escrow internal escrow;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal lp = makeAddr("lp");
    address internal owner = makeAddr("owner");
    address internal seller = makeAddr("seller");
    address internal verifier = makeAddr("verifier");
    address internal arbiter = makeAddr("arbiter");

    uint256 internal agentPk = 0xA11CE;
    address internal agent;

    uint256 internal lineId;

    function setUp() public virtual {
        agent = vm.addr(agentPk);
        usdc = new MockUSDC();
        pool = new CreditPool(usdc, admin, 0);
        tabs = new TabManager(usdc, pool, admin, treasury);
        escrow = new Escrow(usdc, ITabManager(address(tabs)), admin);

        vm.startPrank(admin);
        pool.grantRole(pool.MANAGER_ROLE(), address(tabs));
        tabs.setEscrow(address(escrow));
        escrow.grantRole(escrow.VERIFIER_ROLE(), verifier);
        escrow.grantRole(escrow.ARBITER_ROLE(), arbiter);
        vm.stopPrank();

        // LP funds the pool.
        usdc.mint(lp, 1_000_000 * USDC);
        vm.startPrank(lp);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(1_000_000 * USDC, lp);
        vm.stopPrank();

        // Owner opens a secured line: 1,000 USDC collateral, $100 per payment, $500 budget.
        usdc.mint(owner, 10_000 * USDC);
        vm.startPrank(owner);
        usdc.approve(address(tabs), type(uint256).max);
        lineId = tabs.openLine(agent);
        tabs.depositCollateral(lineId, 1_000 * USDC);
        tabs.setMandate(lineId, uint128(100 * USDC), uint128(500 * USDC), uint64(block.timestamp + 30 days), bytes32(0));
        vm.stopPrank();
    }

    function _intent(uint256 amount, uint256 nonce, bool escrowed)
        internal
        view
        returns (TabManager.PaymentIntent memory p)
    {
        p = TabManager.PaymentIntent({
            lineId: lineId,
            epoch: tabs.getLine(lineId).epoch,
            seller: seller,
            amount: amount,
            resource: keccak256("GET https://api.example/data"),
            escrowed: escrowed,
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });
    }

    function _sign(TabManager.PaymentIntent memory p, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = tabs.hashIntent(p);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _pay(TabManager.PaymentIntent memory p) internal returns (uint256) {
        return tabs.pay(p, _sign(p, agentPk), new bytes32[](0));
    }

    function _payExpectRevert(TabManager.PaymentIntent memory p, bytes memory err) internal {
        bytes memory sig = _sign(p, agentPk);
        vm.expectRevert(err);
        tabs.pay(p, sig, new bytes32[](0));
    }

    function _outstanding(uint256 id) internal view returns (uint256) {
        return tabs.outstandingOf(id);
    }

    function _collateral(uint256 id) internal view returns (uint256) {
        return tabs.getLine(id).collateral;
    }

    function _dueAt(uint256 id) internal view returns (uint256 d) {
        (,,, d,) = tabs.statementOf(id);
    }

    function _cycleEnd(uint256 id) internal view returns (uint256 c) {
        (,,,, c) = tabs.statementOf(id);
    }
}
