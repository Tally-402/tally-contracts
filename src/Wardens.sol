// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IIdentityRegistry, IWardenRenderer} from "./interfaces/IWardens.sol";

/// @title Wardens
/// @notice 2,000 Tally Wardens on Ethereum, minted in one wave. Each Warden has a role (Underwriter, Juror or
///         Verifier) and, once its holder activates it, its own ERC-8004 agent identity.
///
///         The identity is registered and held by this contract, so it can never be separated from its Warden:
///         whoever holds the Warden controls the agent (its registration file, operator wallet and metadata),
///         and a sale moves that control with the token. The Warden's record (rank, accuracy, history) lives
///         under its agent id, so it travels with the Warden. On every transfer the agent's operator wallet is
///         cleared, so the previous holder's operator can't keep acting for it.
///
///         Art and metadata are not fixed: tokenURI comes from a replaceable renderer (or a base URI) until the
///         owner calls freezeMetadata(), which is one-way. The sale itself lives in WardenMint.
contract Wardens is ERC721, Ownable2Step, IERC721Receiver {
    using Strings for uint256;

    uint256 public constant MAX_SUPPLY = 2_000;
    /// @notice Metadata key set on every Warden's ERC-8004 identity: abi.encode(address(this), tokenId).
    string public constant WARDEN_KEY = "tally.warden";

    enum Role {
        Underwriter,
        Juror,
        Verifier
    }

    IIdentityRegistry public immutable identityRegistry;

    /// @notice The sale contract (WardenMint). Set once; can be cut off for good after the wave.
    address public minter;
    bool public mintingClosed;
    uint256 public totalMinted;

    mapping(uint256 tokenId => uint256) public agentIdOf; // 0 until activated
    mapping(uint256 agentId => uint256) public tokenOfAgent;

    IWardenRenderer public renderer; // when set, it renders tokenURI
    string public baseURI; // otherwise baseURI + tokenId
    bool public metadataFrozen;

    event MinterSet_(address minter);
    event MintingClosed(uint256 supply);
    event Activated(uint256 indexed tokenId, uint256 indexed agentId, Role role);
    event RendererSet(address renderer);
    event BaseURISet(string baseURI);
    event MetadataFrozen();
    /// @dev EIP-4906: marketplaces refresh metadata on these.
    event MetadataUpdate(uint256 tokenId);
    event BatchMetadataUpdate(uint256 fromTokenId, uint256 toTokenId);

    error ZeroAddress();
    error SoldOut();
    error MinterSet();
    error NotAuthorized();
    error AlreadyActive();
    error NotActive();
    error ReservedKey();
    error Frozen();
    error UnexpectedToken();

    constructor(address owner_, IIdentityRegistry registry_) ERC721("Tally Wardens", "WARDEN") Ownable(owner_) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        identityRegistry = registry_;
    }

    // ---------------------------------------------------------------- mint (through WardenMint)

    function setMinter(address minter_) external onlyOwner {
        if (minter != address(0) || mintingClosed) revert MinterSet();
        if (minter_ == address(0)) revert ZeroAddress();
        minter = minter_;
        emit MinterSet_(minter_);
    }

    /// @notice End minting forever. Supply stays at what was minted (at most 2,000).
    function closeMinting() external onlyOwner {
        mintingClosed = true;
        emit MintingClosed(totalMinted);
    }

    /// @notice Mint the next `quantity` Wardens to `to`. Ids run from 1 to 2,000.
    function mint(address to, uint256 quantity) external returns (uint256 firstId) {
        if (msg.sender != minter || mintingClosed) revert NotAuthorized();
        firstId = totalMinted + 1;
        if (quantity == 0 || firstId + quantity - 1 > MAX_SUPPLY) revert SoldOut();
        totalMinted += quantity;
        for (uint256 id = firstId; id < firstId + quantity; ++id) {
            _mint(to, id);
        }
    }

    // ---------------------------------------------------------------- roles

    /// @notice Underwriter, Juror or Verifier, fixed by token id (id % 3).
    function roleOf(uint256 tokenId) public view returns (Role) {
        _requireOwned(tokenId);
        return Role(tokenId % 3);
    }

    // ---------------------------------------------------------------- ERC-8004 identity

    modifier onlyHolder(uint256 tokenId) {
        if (!_isAuthorized(_requireOwned(tokenId), msg.sender, tokenId)) revert NotAuthorized();
        _;
    }

    function _agent(uint256 tokenId) internal view returns (uint256 agentId) {
        agentId = agentIdOf[tokenId];
        if (agentId == 0) revert NotActive();
    }

    /// @notice Give this Warden its ERC-8004 identity, registered and held by this contract.
    /// @param agentURI The agent's registration file (name, description, services).
    function activate(uint256 tokenId, string calldata agentURI)
        external
        onlyHolder(tokenId)
        returns (uint256 agentId)
    {
        if (agentIdOf[tokenId] != 0) revert AlreadyActive();
        agentId = identityRegistry.register(agentURI);
        agentIdOf[tokenId] = agentId;
        tokenOfAgent[agentId] = tokenId;
        identityRegistry.setMetadata(agentId, WARDEN_KEY, abi.encode(address(this), tokenId));
        emit Activated(tokenId, agentId, Role(tokenId % 3));
        emit MetadataUpdate(tokenId);
    }

    function setAgentURI(uint256 tokenId, string calldata newURI) external onlyHolder(tokenId) {
        identityRegistry.setAgentURI(_agent(tokenId), newURI);
    }

    /// @notice Point the agent at the wallet that runs it (a model's operator). The wallet proves control with
    ///         the EIP-712 or ERC-1271 signature the registry expects.
    function setAgentWallet(uint256 tokenId, address wallet, uint256 deadline, bytes calldata signature)
        external
        onlyHolder(tokenId)
    {
        identityRegistry.setAgentWallet(_agent(tokenId), wallet, deadline, signature);
    }

    function unsetAgentWallet(uint256 tokenId) external onlyHolder(tokenId) {
        identityRegistry.unsetAgentWallet(_agent(tokenId));
    }

    function setAgentMetadata(uint256 tokenId, string calldata key, bytes calldata value) external onlyHolder(tokenId) {
        if (keccak256(bytes(key)) == keccak256(bytes(WARDEN_KEY))) revert ReservedKey();
        identityRegistry.setMetadata(_agent(tokenId), key, value);
    }

    /// @dev Accept only the identities this contract registers.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(identityRegistry)) revert UnexpectedToken();
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @dev On a transfer (not a mint), clear the agent's operator wallet: the new holder sets their own.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        uint256 agentId = agentIdOf[tokenId];
        if (from != address(0) && agentId != 0 && identityRegistry.getAgentWallet(agentId) != address(0)) {
            identityRegistry.unsetAgentWallet(agentId);
        }
    }

    // ---------------------------------------------------------------- metadata (replaceable until frozen)

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (address(renderer) != address(0)) return renderer.tokenURI(tokenId);
        return bytes(baseURI).length == 0 ? "" : string.concat(baseURI, tokenId.toString());
    }

    function setRenderer(IWardenRenderer renderer_) external onlyOwner {
        if (metadataFrozen) revert Frozen();
        renderer = renderer_;
        emit RendererSet(address(renderer_));
        emit BatchMetadataUpdate(1, MAX_SUPPLY);
    }

    function setBaseURI(string calldata baseURI_) external onlyOwner {
        if (metadataFrozen) revert Frozen();
        baseURI = baseURI_;
        emit BaseURISet(baseURI_);
        emit BatchMetadataUpdate(1, MAX_SUPPLY);
    }

    /// @notice Make the current renderer and base URI permanent. One-way.
    function freezeMetadata() external onlyOwner {
        metadataFrozen = true;
        emit MetadataFrozen();
    }

    /// @notice Ask marketplaces to refresh a Warden's metadata, e.g. after its rank changes.
    function refreshMetadata(uint256 fromTokenId, uint256 toTokenId) external onlyOwner {
        emit BatchMetadataUpdate(fromTokenId, toTokenId);
    }

    function supportsInterface(bytes4 id) public view override returns (bool) {
        return id == bytes4(0x49064906) || super.supportsInterface(id); // EIP-4906
    }
}
