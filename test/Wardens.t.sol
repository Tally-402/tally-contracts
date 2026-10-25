// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Wardens} from "../src/Wardens.sol";
import {WardenMint, IWardensMint} from "../src/WardenMint.sol";
import {IIdentityRegistry, IWardenRenderer} from "../src/interfaces/IWardens.sol";
import {Mock8004Registry} from "./mocks/Mock8004Registry.sol";

contract FixedRenderer is IWardenRenderer {
    function tokenURI(uint256 tokenId) external pure returns (string memory) {
        return string.concat("data:application/json,{\"id\":", vm_toString(tokenId), "}");
    }

    function vm_toString(uint256 v) internal pure returns (string memory s) {
        if (v == 0) return "0";
        while (v > 0) {
            s = string.concat(string(abi.encodePacked(bytes1(uint8(48 + v % 10)))), s);
            v /= 10;
        }
    }
}

contract WardensTest is Test {
    Mock8004Registry reg;
    Wardens wardens;
    WardenMint sale;

    address owner = makeAddr("owner");
    address tranche = makeAddr("firstLoss");
    address alice = makeAddr("alice"); // on the allowlist
    address bob = makeAddr("bob"); // on the allowlist
    address carol = makeAddr("carol"); // public
    uint256 operatorPk = 0x0BE7;
    uint128 constant PRICE = 0.05 ether;
    uint64 t0;

    function setUp() public {
        vm.warp(1_800_000_000);
        t0 = uint64(vm.getBlockTimestamp());
        reg = new Mock8004Registry();
        wardens = new Wardens(owner, IIdentityRegistry(address(reg)));
        sale = new WardenMint(owner, IWardensMint(address(wardens)), tranche);
        vm.prank(owner);
        wardens.setMinter(address(sale));
        vm.prank(owner);
        sale.configure(_config(3));
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 1_000 ether);
    }

    // ---------------------------------------------------------------- helpers

    function _leaf(address a) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a))));
    }

    function _root() internal view returns (bytes32) {
        (bytes32 a, bytes32 b) = (_leaf(alice), _leaf(bob));
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _proof(address who) internal view returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = who == alice ? _leaf(bob) : _leaf(alice);
    }

    function _config(uint16 maxPerWallet) internal view returns (WardenMint.Config memory) {
        return WardenMint.Config(t0 + 1 hours, t0 + 1 days, t0 + 3 days, maxPerWallet, PRICE, _root());
    }

    function _mintTo(address who, uint256 n) internal returns (uint256 first) {
        vm.warp(t0 + 1 days);
        vm.prank(who);
        first = sale.mintPublic{value: PRICE * n}(n);
    }

    // ---------------------------------------------------------------- sale

    function test_AllowlistThenPublic() public {
        vm.warp(t0 + 1 hours);
        vm.prank(alice);
        uint256 first = sale.mintAllowlist{value: PRICE * 2}(2, _proof(alice));
        assertEq(first, 1);
        assertEq(wardens.ownerOf(1), alice);
        assertEq(wardens.ownerOf(2), alice);

        vm.prank(carol);
        vm.expectRevert(WardenMint.Closed.selector);
        sale.mintPublic{value: PRICE}(1);

        vm.prank(carol);
        vm.expectRevert(WardenMint.NotOnAllowlist.selector);
        sale.mintAllowlist{value: PRICE}(1, _proof(alice));

        vm.warp(t0 + 1 days);
        vm.prank(carol);
        assertEq(sale.mintPublic{value: PRICE}(1), 3);
        assertEq(wardens.totalMinted(), 3);
    }

    function test_RevertWhen_OutsideTheWave() public {
        vm.prank(alice);
        vm.expectRevert(WardenMint.Closed.selector);
        sale.mintAllowlist{value: PRICE}(1, _proof(alice));
        vm.warp(t0 + 3 days);
        vm.prank(carol);
        vm.expectRevert(WardenMint.Closed.selector);
        sale.mintPublic{value: PRICE}(1);
    }

    function test_ExactPaymentAndWalletLimit() public {
        vm.warp(t0 + 1 days);
        vm.startPrank(carol);
        vm.expectRevert(WardenMint.WrongPayment.selector);
        sale.mintPublic{value: PRICE - 1}(1);
        vm.expectRevert(WardenMint.WrongPayment.selector);
        sale.mintPublic{value: 0}(0);
        sale.mintPublic{value: PRICE * 3}(3);
        vm.expectRevert(WardenMint.WalletLimit.selector);
        sale.mintPublic{value: PRICE}(1);
        vm.stopPrank();
    }

    function test_TermsLockWhenTheWaveOpens() public {
        vm.warp(t0 + 1 hours);
        vm.prank(owner);
        vm.expectRevert(WardenMint.TermsLocked.selector);
        sale.configure(_config(10));
    }

    function test_OnlyOwnerConfigures() public {
        vm.prank(carol);
        vm.expectRevert();
        sale.configure(_config(10));
    }

    function test_ProceedsOnlyGoToFirstLoss() public {
        _mintTo(carol, 3);
        vm.prank(carol);
        sale.sendProceeds();
        assertEq(tranche.balance, PRICE * 3);
        assertEq(address(sale).balance, 0);
    }

    function test_SupplyCappedAt2000() public {
        vm.prank(owner);
        sale.configure(_config(2_000));
        vm.warp(t0 + 1 days);
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(carol);
            sale.mintPublic{value: PRICE * 100}(100);
        }
        assertEq(wardens.totalMinted(), 2_000);
        assertEq(wardens.ownerOf(2_000), carol);
        vm.prank(bob);
        vm.expectRevert(Wardens.SoldOut.selector);
        sale.mintPublic{value: PRICE}(1);
    }

    function test_OnlyTheSaleMints_AndMintingCanClose() public {
        vm.prank(carol);
        vm.expectRevert(Wardens.NotAuthorized.selector);
        wardens.mint(carol, 1);

        vm.prank(owner);
        vm.expectRevert(Wardens.MinterSet.selector);
        wardens.setMinter(carol);

        _mintTo(carol, 1);
        vm.prank(owner);
        wardens.closeMinting();
        vm.warp(t0 + 1 days + 1);
        vm.prank(carol);
        vm.expectRevert(Wardens.NotAuthorized.selector);
        sale.mintPublic{value: PRICE}(1);
    }

    // ---------------------------------------------------------------- roles

    function test_RolesFollowTokenId() public {
        _mintTo(carol, 3);
        assertEq(uint8(wardens.roleOf(1)), uint8(Wardens.Role.Juror));
        assertEq(uint8(wardens.roleOf(2)), uint8(Wardens.Role.Verifier));
        assertEq(uint8(wardens.roleOf(3)), uint8(Wardens.Role.Underwriter));
    }

    // ---------------------------------------------------------------- ERC-8004 identity

    function _activate(address holder, uint256 tokenId) internal returns (uint256 agentId) {
        vm.prank(holder);
        agentId = wardens.activate(tokenId, "ipfs://warden-card");
    }

    function _walletSig(uint256 agentId, address wallet, uint256 deadline) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, reg.walletDigest(agentId, wallet, deadline));
        return abi.encodePacked(r, s, v);
    }

    function test_ActivateGivesTheWardenAnIdentityHeldByTheCollection() public {
        _mintTo(carol, 1);
        uint256 agentId = _activate(carol, 1);
        assertEq(reg.ownerOf(agentId), address(wardens), "the collection holds the identity");
        assertEq(wardens.agentIdOf(1), agentId);
        assertEq(wardens.tokenOfAgent(agentId), 1);
        assertEq(reg.agentURIOf(agentId), "ipfs://warden-card");
        (address col, uint256 tok) = abi.decode(reg.getMetadata(agentId, wardens.WARDEN_KEY()), (address, uint256));
        assertEq(col, address(wardens));
        assertEq(tok, 1);

        vm.prank(carol);
        vm.expectRevert(Wardens.AlreadyActive.selector);
        wardens.activate(1, "ipfs://again");
    }

    function test_OnlyHolderOrApprovedManagesTheAgent() public {
        _mintTo(carol, 1);
        vm.prank(alice);
        vm.expectRevert(Wardens.NotAuthorized.selector);
        wardens.activate(1, "ipfs://x");

        vm.prank(carol);
        wardens.approve(alice, 1);
        uint256 agentId = _activate(alice, 1);

        vm.prank(alice);
        wardens.setAgentURI(1, "ipfs://v2");
        assertEq(reg.agentURIOf(agentId), "ipfs://v2");

        vm.prank(bob);
        vm.expectRevert(Wardens.NotAuthorized.selector);
        wardens.setAgentURI(1, "ipfs://hijack");
    }

    function test_HolderSetsOperatorWallet_AndASaleClearsIt() public {
        _mintTo(carol, 1);
        uint256 agentId = _activate(carol, 1);
        address operator = vm.addr(operatorPk);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _walletSig(agentId, operator, deadline);
        vm.prank(carol);
        wardens.setAgentWallet(1, operator, deadline, sig);
        assertEq(reg.getAgentWallet(agentId), operator);

        // Sold: the identity stays with the Warden, the old operator is removed, the new holder takes control.
        vm.prank(carol);
        wardens.transferFrom(carol, bob, 1);
        assertEq(reg.ownerOf(agentId), address(wardens));
        assertEq(wardens.agentIdOf(1), agentId, "record travels with the Warden");
        assertEq(reg.getAgentWallet(agentId), address(0), "previous operator cleared");

        vm.prank(carol);
        vm.expectRevert(Wardens.NotAuthorized.selector);
        wardens.setAgentURI(1, "ipfs://old-holder");
        vm.prank(bob);
        wardens.setAgentURI(1, "ipfs://new-holder");
        assertEq(reg.agentURIOf(agentId), "ipfs://new-holder");
    }

    function test_TransferOfInactiveWardenSkipsTheRegistry() public {
        _mintTo(carol, 1);
        vm.prank(carol);
        wardens.transferFrom(carol, bob, 1);
        assertEq(wardens.ownerOf(1), bob);
    }

    function test_WardenKeyIsReserved() public {
        _mintTo(carol, 1);
        _activate(carol, 1);
        string memory key = wardens.WARDEN_KEY();
        vm.prank(carol);
        vm.expectRevert(Wardens.ReservedKey.selector);
        wardens.setAgentMetadata(1, key, abi.encode(address(1), uint256(99)));
        vm.prank(carol);
        wardens.setAgentMetadata(1, "operator", bytes("claude"));
    }

    function test_RevertWhen_ManagingAnInactiveWarden() public {
        _mintTo(carol, 1);
        vm.prank(carol);
        vm.expectRevert(Wardens.NotActive.selector);
        wardens.setAgentURI(1, "ipfs://x");
    }

    function test_RejectsStrayNfts() public {
        vm.expectRevert(Wardens.UnexpectedToken.selector);
        wardens.onERC721Received(address(this), address(this), 1, "");
    }

    // ---------------------------------------------------------------- art is replaceable until frozen

    function test_ArtIsReplaceableUntilFrozen() public {
        _mintTo(carol, 1);
        assertEq(wardens.tokenURI(1), "");
        vm.startPrank(owner);
        wardens.setBaseURI("https://meta.tally.example/wardens/");
        assertEq(wardens.tokenURI(1), "https://meta.tally.example/wardens/1");
        FixedRenderer r = new FixedRenderer();
        wardens.setRenderer(r);
        assertEq(wardens.tokenURI(1), "data:application/json,{\"id\":1}");
        wardens.setRenderer(IWardenRenderer(address(0)));
        assertEq(wardens.tokenURI(1), "https://meta.tally.example/wardens/1");
        wardens.freezeMetadata();
        vm.expectRevert(Wardens.Frozen.selector);
        wardens.setRenderer(r);
        vm.expectRevert(Wardens.Frozen.selector);
        wardens.setBaseURI("ipfs://other/");
        vm.stopPrank();
    }

    function test_OnlyOwnerChangesArt() public {
        vm.prank(carol);
        vm.expectRevert();
        wardens.setBaseURI("https://evil.example/");
    }

    function test_SupportsErc721AndEip4906() public view {
        assertTrue(wardens.supportsInterface(0x80ac58cd));
        assertTrue(wardens.supportsInterface(0x49064906));
    }
}
