pragma solidity ^0.8.15;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import {IEscrowToken} from "./interfaces/IEscrowToken.sol";
import {ILienToken} from "./interfaces/ILienToken.sol";
import {CollateralLookup} from "./libraries/CollateralLookup.sol";
import {ITransferProxy} from "./interfaces/ITransferProxy.sol";
import {IAstariaRouter} from "./interfaces/IAstariaRouter.sol";
import {IVault, VaultImplementation} from "./VaultImplementation.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

interface IInvoker {
    function onBorrowAndBuy(
        bytes calldata data,
        address token,
        uint256 amount,
        address payable recipient
    ) external returns (bool);
}

contract AstariaRouter is Auth, IAstariaRouter {
    using SafeERC20 for IERC20;
    using CollateralLookup for address;
    using FixedPointMathLib for uint256;

    bytes32 public immutable DOMAIN_SEPARATOR;
    IERC20 public immutable WETH;
    IEscrowToken public immutable ESCROW_TOKEN;
    ILienToken public immutable LIEN_TOKEN;
    ITransferProxy public immutable TRANSFER_PROXY;
    address public VAULT_IMPLEMENTATION;
    address public SOLO_IMPLEMENTATION;
    address public WITHDRAW_IMPLEMENTATION;

    address public feeTo;

    uint256 public LIQUIDATION_FEE_PERCENT;
    uint256 public APPRAISER_ORIGINATION_FEE_NUMERATOR;
    uint256 public APPRAISER_ORIGINATION_FEE_BASE;
    uint64 public MIN_INTEREST_BPS;
    uint64 public MIN_DURATION_INCREASE;

    //public vault contract => appraiser
    mapping(address => address) public vaults; //TODO: its currently keyed address to BondVault struct,
    mapping(address => uint256) public appraiserNonce;

    // See https://eips.ethereum.org/EIPS/eip-191
    string private constant EIP191_PREFIX_FOR_EIP712_STRUCTURED_DATA =
        "\x19\x01";

    //
    //    bytes32 private constant NEW_VAULT_SIGNATURE_HASH =
    //        keccak256(
    //            "NewBondVault(address appraiser,address delegate,uint256 expiration,uint256 nonce,uint256 deadline)"
    //        );

    constructor(
        Authority _AUTHORITY,
        address _WETH,
        address _ESCROW_TOKEN,
        address _LIEN_TOKEN,
        address _TRANSFER_PROXY,
        address _VAULT_IMPL,
        address _SOLO_IMPL
    ) Auth(address(msg.sender), _AUTHORITY) {
        WETH = IERC20(_WETH);
        ESCROW_TOKEN = IEscrowToken(_ESCROW_TOKEN);
        LIEN_TOKEN = ILienToken(_LIEN_TOKEN);
        TRANSFER_PROXY = ITransferProxy(_TRANSFER_PROXY);
        VAULT_IMPLEMENTATION = _VAULT_IMPL;
        SOLO_IMPLEMENTATION = _SOLO_IMPL;
        LIQUIDATION_FEE_PERCENT = 13;
        MIN_INTEREST_BPS = 5; //5 bps
        APPRAISER_ORIGINATION_FEE_NUMERATOR = 200;
        APPRAISER_ORIGINATION_FEE_BASE = 1000;
        MIN_DURATION_INCREASE = 14 days;
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("BrokerRouter"),
                keccak256("1"),
                chainId,
                address(this)
            )
        );
    }

    function file(bytes32 what, bytes calldata data) external requiresAuth {
        if (what == "LIQUIDATION_FEE_PERCENT") {
            uint256 value = abi.decode(data, (uint256));
            LIQUIDATION_FEE_PERCENT = value;
        } else if (what == "MIN_INTEREST_BPS") {
            uint256 value = abi.decode(data, (uint256));
            MIN_INTEREST_BPS = uint64(value);
        } else if (what == "APPRAISER_NUMERATOR") {
            uint256 value = abi.decode(data, (uint256));
            APPRAISER_ORIGINATION_FEE_NUMERATOR = value;
        } else if (what == "APPRAISER_ORIGINATION_FEE_BASE") {
            uint256 value = abi.decode(data, (uint256));
            APPRAISER_ORIGINATION_FEE_BASE = value;
        } else if (what == "MIN_DURATION_INCREASE") {
            uint256 value = abi.decode(data, (uint256));
            MIN_DURATION_INCREASE = uint64(value);
        } else if (what == "feeTo") {
            address addr = abi.decode(data, (address));
            feeTo = addr;
        } else if (what == "WITHDRAW_IMPLEMENTATION") {
            address addr = abi.decode(data, (address));
            WITHDRAW_IMPLEMENTATION = addr;
        } else if (what == "VAULT_IMPLEMENTATION") {
            address addr = abi.decode(data, (address));
            VAULT_IMPLEMENTATION = addr;
        } else {
            revert("unsupported/file");
        }
    }

    // MODIFIERS
    modifier onlyVaults() {
        //TODO: set this back up correctly
        //        require(
        //            brokerHashes[msg.sender] != bytes32(0),
        //            "this vault has not been initialized"
        //        );
        _;
    }

    //PUBLIC

    //todo: check all incoming obligations for validity
    // execute the borrows
    //transfer the vaulted nfts to the sender
    // transfer the collateral to the sender
    function commitToLoans(IAstariaRouter.Commitment[] calldata commitments)
        external
        returns (uint256 totalBorrowed)
    {
        totalBorrowed = 0;
        for (uint256 i = 0; i < commitments.length; ++i) {
            _transferAndDepositAsset(
                commitments[i].tokenContract,
                commitments[i].tokenId
            );
            totalBorrowed += _executeCommitment(commitments[i]);

            uint256 escrowId = commitments[i].tokenContract.computeId(
                commitments[i].tokenId
            );
            _returnCollateral(escrowId, address(msg.sender));
        }
        WETH.safeApprove(address(TRANSFER_PROXY), totalBorrowed);
        TRANSFER_PROXY.tokenTransferFrom(
            address(WETH),
            address(this),
            address(msg.sender),
            totalBorrowed
        );
    }

    //    function encodeBondVaultHash(
    //        address appraiser,
    //        address delegate,
    //        uint256 nonce,
    //        uint256 deadline,
    //        uint256 buyout
    //    ) public view returns (bytes memory) {
    //        return
    //            abi.encode(
    //                EIP191_PREFIX_FOR_EIP712_STRUCTURED_DATA,
    //                DOMAIN_SEPARATOR,
    //                keccak256(
    //                    abi.encode(
    //                        NEW_VAULT_SIGNATURE_HASH,
    //                        appraiser,
    //                        delegate,
    //                        nonce,
    //                        deadline
    //                    )
    //                )
    //            );
    //    }

    // verifies the signature on the root of the merkle tree to be the appraiser
    // we need an additional method to prevent a griefing attack where the signature is stripped off and reserrved by an attacker

    function newVault() external returns (address) {
        return _newBondVault(uint256(0));
    }

    function newPublicVault(uint256 epochLength) external returns (address) {
        return _newBondVault(epochLength);
    }

    //    function borrowAndBuy(BorrowAndBuyParams memory params) external {
    //        uint256 spendableBalance;
    //        for (uint256 i = 0; i < params.commitments.length; ++i) {
    //            _executeCommitment(params.commitments[i]);
    //            spendableBalance += params.commitments[i].amount; //amount borrowed
    //        }
    //        require(
    //            params.purchasePrice <= spendableBalance,
    //            "purchase price cannot be for more than your aggregate loan"
    //        );
    //
    //        WETH.safeApprove(params.invoker, params.purchasePrice);
    //        require(
    //            IInvoker(params.invoker).onBorrowAndBuy(
    //                params.purchaseData, // calldata for the invoker
    //                address(WETH), // token
    //                params.purchasePrice, //max approval
    //                payable(msg.sender) // recipient
    //            ),
    //            "borrow and buy failed"
    //        );
    //        if (spendableBalance - params.purchasePrice > uint256(0)) {
    //            WETH.safeTransfer(
    //                msg.sender,
    //                spendableBalance - params.purchasePrice
    //            );
    //        }
    //    }

    function buyoutLien(
        uint256 position,
        IAstariaRouter.Commitment memory incomingTerms //        onlyNetworkBrokers( //            outgoingTerms.escrowId, //            outgoingTerms.position //        )
    ) external {
        VaultImplementation(incomingTerms.nor.strategy.vault).buyoutLien(
            incomingTerms.tokenContract.computeId(incomingTerms.tokenId),
            position,
            incomingTerms
        );
    }

    function requestLienPosition(ILienToken.LienActionEncumber calldata params)
        external
        onlyVaults
        returns (uint256)
    {
        return LIEN_TOKEN.createLien(params);
    }

    function lendToVault(address vault, uint256 amount) external {
        TRANSFER_PROXY.tokenTransferFrom(
            address(WETH),
            address(msg.sender),
            address(this),
            amount
        );

        require(
            vaults[vault] != address(0),
            "lendToVault: vault doesn't exist"
        );
        WETH.safeApprove(vault, amount);
        IVault(vault).deposit(amount, address(msg.sender));
    }

    function canLiquidate(uint256 escrowId, uint256 position)
        public
        view
        returns (bool)
    {
        ILienToken.Lien memory lien = LIEN_TOKEN.getLien(escrowId, position);

        uint256 interestAccrued = LIEN_TOKEN.getInterest(escrowId, position);
        // uint256 maxInterest = (lien.amount * lien.schedule) / 100

        return (lien.start + lien.duration <= block.timestamp &&
            lien.amount > 0);
    }

    // person calling liquidate should get some incentive from the auction
    function liquidate(uint256 escrowId, uint256 position)
        external
        returns (uint256 reserve)
    {
        require(
            canLiquidate(escrowId, position),
            "liquidate: borrow is healthy"
        );

        // 0x

        reserve = ESCROW_TOKEN.auctionVault(
            escrowId,
            address(msg.sender),
            LIQUIDATION_FEE_PERCENT
        );

        emit Liquidation(escrowId, position, reserve);
    }

    function getAppraiserFee() external view returns (uint256, uint256) {
        return (
            APPRAISER_ORIGINATION_FEE_NUMERATOR,
            APPRAISER_ORIGINATION_FEE_BASE
        );
    }

    function isValidVault(address vault) external view returns (bool) {
        return vaults[vault] != address(0);
    }

    function isValidRefinance(IAstariaRouter.RefinanceCheckParams memory params)
        external
        view
        returns (bool)
    {
        ILienToken.Lien memory lien = LIEN_TOKEN.getLien(
            params.incoming.escrowId,
            params.position
        );
        // uint256 minNewRate = (((lien.rate * MIN_INTEREST_BPS) / 1000));
        uint256 minNewRate = uint256(lien.rate).mulDivDown(
            MIN_INTEREST_BPS,
            1000
        );

        if (params.incoming.rate > minNewRate) {
            revert InvalidRefinanceRate(params.incoming.rate);
        }

        if (
            (block.timestamp + params.incoming.duration) -
                (lien.start + lien.duration) <
            MIN_DURATION_INCREASE
        ) {
            revert InvalidRefinanceDuration(params.incoming.duration);
        }

        return true;
    }

    //INTERNAL FUNCS

    function _newBondVault(uint256 epochLength) internal returns (address) {
        //        require(
        //            params.appraiser != address(0),
        //            "BrokerRouter.newBondVault(): Appraiser address cannot be zero"
        //        );
        //        require(
        //            bondVaults[params.root].appraiser == address(0),
        //            "BrokerRouter.newBondVault(): Root of BondVault already instantiated"
        //        );
        //        require(
        //            block.timestamp < params.deadline,
        //            "BrokerRouter.newBondVault(): Expired"
        //        );
        //        bytes32 digest = keccak256(
        //            encodeBondVaultHash(
        //                params.appraiser,
        //                address(0),
        //                //                params.expiration,
        //                appraiserNonce[params.appraiser]++,
        //                params.deadline,
        //                params.buyout
        //            )
        //        );

        //        address recoveredAddress = ecrecover(
        //            digest,
        //            params.v,
        //            params.r,
        //            params.s
        //        );
        //        require(
        //            recoveredAddress == params.appraiser,
        //            "newBondVault: Invalid Signature"
        //        );

        uint256 brokerType;

        address implementation;
        if (epochLength > uint256(0)) {
            require(
                epochLength >= 3 days,
                "epochLength must be at least 3 days"
            );
            implementation = VAULT_IMPLEMENTATION;
            brokerType = 2;
        } else {
            implementation = SOLO_IMPLEMENTATION;
            brokerType = 1;
        }

        address vaultAddr = ClonesWithImmutableArgs.clone(
            implementation,
            abi.encodePacked(
                address(msg.sender),
                address(WETH),
                address(ESCROW_TOKEN),
                address(this),
                address(ESCROW_TOKEN.AUCTION_HOUSE()),
                block.timestamp,
                epochLength,
                brokerType
            )
        );
        //        BondVault storage bondVault = bondVaults[params.root];
        //        bondVault.appraiser = params.appraiser;
        //        bondVault.expiration = params.expiration;
        //        bondVault.broker = broker;

        //        brokerHashes[broker] = params.root;

        vaults[vaultAddr] = msg.sender;

        emit NewVault(msg.sender, vaultAddr);

        return vaultAddr;
    }

    function _executeCommitment(IAstariaRouter.Commitment memory c)
        internal
        returns (uint256)
    {
        uint256 escrowId = c.tokenContract.computeId(c.tokenId);
        require(
            msg.sender == ESCROW_TOKEN.ownerOf(escrowId),
            "invalid sender for escrowId"
        );
        return _borrow(c, address(this));
    }

    function _borrow(IAstariaRouter.Commitment memory c, address receiver)
        internal
        returns (uint256)
    {
        //router must be approved for the star nft to take a loan,
        VaultImplementation(c.nor.strategy.vault).commitToLoan(c, receiver);
        if (receiver == address(this)) {
            return c.nor.amount;
        }
        return uint256(0);
    }

    function _transferAndDepositAsset(address tokenContract, uint256 tokenId)
        internal
    {
        IERC721(tokenContract).transferFrom(
            address(msg.sender),
            address(this),
            tokenId
        );

        IERC721(tokenContract).approve(address(ESCROW_TOKEN), tokenId);

        ESCROW_TOKEN.depositERC721(address(this), tokenContract, tokenId);
    }

    function _returnCollateral(uint256 escrowId, address receiver) internal {
        ESCROW_TOKEN.transferFrom(address(this), receiver, escrowId);
    }

    function _addLien(ILienToken.LienActionEncumber memory params) internal {
        LIEN_TOKEN.createLien(params);
    }
}