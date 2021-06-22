// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.5;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./utils/Bits.sol";
import "./utils/Bitfield.sol";
import "./ValidatorRegistry.sol";
import "./MMRVerification.sol";
import "./Blake2b.sol";
import "./ScaleCodec.sol";

/**
 * @title A entry contract for the Ethereum light client
 */
contract BeefyLightClient {
    using Bits for uint256;
    using Bitfield for uint256[];
    using ScaleCodec for uint256;
    using ScaleCodec for uint64;
    using ScaleCodec for uint32;
    using ScaleCodec for uint16;

    /* Events */

    /**
     * @notice Notifies an observer that the prover's attempt at initital
     * verification was successful.
     * @dev Note that the prover must wait until `n` blocks have been mined
     * subsequent to the generation of this event before the 2nd tx can be sent
     * @param prover The address of the calling prover
     * @param blockNumber The blocknumber in which the initial validation
     * succeeded
     * @param id An identifier to provide disambiguation
     */
    event InitialVerificationSuccessful(
        address prover,
        uint256 blockNumber,
        uint256 id
    );

    /**
     * @notice Notifies an observer that the complete verification process has
     *  finished successfuly and the new commitmentHash will be accepted
     * @param prover The address of the successful prover
     * @param id the identifier used
     */
    event FinalVerificationSuccessful(address prover, uint256 id);

    event NewMMRRoot(bytes32 mmrRoot, uint64 blockNumber);

    /* Types */

    struct Commitment {
        bytes32 payload;
        uint64 blockNumber;
        uint32 validatorSetId;
    }

    /**
     * @param signatures an array of signatures from the randomly chosen validators
     * @param positions an array of the positions of the randomly chosen validators
     * @param publicKeys an array of the public key of each signer
     * @param publicKeyMerkleProofs an array of merkle proofs from the chosen validators
     */
    struct ValidatorProof {
        bytes[] signatures;
        uint256[] positions;
        address[] publicKeys;
        bytes32[][] publicKeyMerkleProofs;
    }

    struct ValidationData {
        address senderAddress;
        bytes32 commitmentHash;
        uint256[] validatorClaimsBitfield;
        uint256 blockNumber;
    }

    struct BeefyMMRLeaf {
        uint32 parentNumber;
        bytes32 parentHash;
        bytes32 parachainHeadsRoot;
        uint64 nextAuthoritySetId;
        uint32 nextAuthoritySetLen;
        bytes32 nextAuthoritySetRoot;
    }

    /* State */

    ValidatorRegistry public validatorRegistry;
    MMRVerification public mmrVerification;
    Blake2b public blake2b;
    uint256 public currentId;
    bytes32 public latestMMRRoot;
    mapping(uint256 => ValidationData) public validationData;

    /* Constants */

    uint256 public constant THRESHOLD_NUMERATOR = 2;
    uint256 public constant THRESHOLD_DENOMINATOR = 3;
    uint256 public constant BLOCK_WAIT_PERIOD = 3;
    uint256 public constant NUMBER_OF_BLOCKS_PER_EPOCH = 3;
    uint256 public constant ERROR_AND_SAFETY_BUFFER = 3;

    /**
     * @notice Deploys the BeefyLightClient contract
     * @dev If the validatorSetRegistry should be initialised with 0 entries, then input
     * 0x00 as validatorSetRoot
     * @param _validatorRegistry The contract to be used as the validator registry
     * @param _mmrVerification The contract to be used for MMR verification
     */
    constructor(
        ValidatorRegistry _validatorRegistry,
        MMRVerification _mmrVerification,
        Blake2b _blake2b
    ) {
        validatorRegistry = _validatorRegistry;
        mmrVerification = _mmrVerification;
        blake2b = _blake2b;
        currentId = 0;
    }

    /* Public Functions */

    /**
     * @notice Executed by the incoming channel in order to verify commitment
     * @param beefyMMRLeaf contains the merkle leaf to be verified
     * @param beefyMMRLeafIndex contains the merkle leaf index
     * @param beefyMMRLeafCount contains the merkle leaf count
     * @param beefyMMRLeafProof contains the merkle proof to verify against
     */
    function verifyBeefyMerkleLeaf(
        bytes32 beefyMMRLeaf,
        uint256 beefyMMRLeafIndex,
        uint256 beefyMMRLeafCount,
        bytes32[] calldata beefyMMRLeafProof
    ) external returns (bool) {
        return
            mmrVerification.verifyInclusionProof(
                latestMMRRoot,
                beefyMMRLeaf,
                beefyMMRLeafIndex,
                beefyMMRLeafCount,
                beefyMMRLeafProof
            );
    }

    /**
     * @notice Executed by the prover in order to begin the process of block
     * acceptance by the light client
     * @param commitmentHash contains the commitmentHash signed by the validator(s)
     * @param validatorClaimsBitfield a bitfield containing a membership status of each
     * validator who has claimed to have signed the commitmentHash
     * @param validatorSignature the signature of one validator
     * @param validatorPosition the position of the validator, index starting at 0
     * @param validatorPublicKey the public key of the validator
     * @param validatorPublicKeyMerkleProof proof required for validation of the public key in the validator merkle tree
     */
    function newSignatureCommitment(
        bytes32 commitmentHash,
        uint256[] memory validatorClaimsBitfield,
        bytes memory validatorSignature,
        uint256 validatorPosition,
        address validatorPublicKey,
        bytes32[] calldata validatorPublicKeyMerkleProof
    ) public payable {
        /**
         * @dev Check if validatorPublicKeyMerkleProof is valid based on ValidatorRegistry merkle root
         */
        require(
            validatorRegistry.checkValidatorInSet(
                validatorPublicKey,
                validatorPosition,
                validatorPublicKeyMerkleProof
            ),
            "Error: Sender must be in validator set at correct position"
        );

        /**
         * @dev Check if validatorSignature is correct, ie. check if it matches
         * the signature of senderPublicKey on the commitmentHash
         */
        require(
            ECDSA.recover(commitmentHash, validatorSignature) ==
                validatorPublicKey,
            "Error: Invalid Signature"
        );

        /**
         * @dev Check that the bitfield actually contains enough claims to be succesful, ie, >= 2/3
         */
        require(
            validatorClaimsBitfield.countSetBits() >=
                requiredNumberOfSignatures(),
            "Error: Bitfield not enough validators"
        );

        /**
         * @todo Lock up the sender stake as collateral
         */
        // TODO

        // Accept and save the commitment
        validationData[currentId] = ValidationData(
            msg.sender,
            commitmentHash,
            validatorClaimsBitfield,
            block.number
        );

        emit InitialVerificationSuccessful(msg.sender, block.number, currentId);

        currentId = currentId + 1;
    }

    function createRandomBitfield(uint256 id)
        public
        view
        returns (uint256[] memory)
    {
        ValidationData storage data = validationData[id];

        /**
         * @dev verify that block wait period has passed
         */
        require(
            block.number >= data.blockNumber + BLOCK_WAIT_PERIOD,
            "Error: Block wait period not over"
        );

        return
            Bitfield.randomNBitsWithPriorCheck(
                getSeed(data),
                data.validatorClaimsBitfield,
                requiredNumberOfSignatures()
            );
    }

    function createInitialBitfield(uint256[] calldata bitsToSet, uint256 length)
        public
        pure
        returns (uint256[] memory)
    {
        return Bitfield.createBitfield(bitsToSet, length);
    }

    /**
     * @notice Performs the second step in the validation logic
     * @param id an identifying value generated in the previous transaction
     * @param commitment contains the full commitment that was used for the commitmentHash
     * @param validatorProof a struct containing the data needed to verify all validator signatures
     */
    function completeSignatureCommitment(
        uint256 id,
        Commitment calldata commitment,
        ValidatorProof calldata validatorProof,
        BeefyMMRLeaf calldata latestMMRLeaf,
        bytes32[] calldata mmrProofItems
    ) public {
        verifyCommitment(id, commitment, validatorProof);
        verifyNewestMMRLeaf(
            latestMMRLeaf,
            mmrProofItems,
            commitment.payload,
            commitment.blockNumber
        );
        /**
         * @follow-up Do we need a try-catch block here?
         */
        processPayload(commitment.payload, commitment.blockNumber);

        emit FinalVerificationSuccessful(msg.sender, id);

        /**
         * @dev We no longer need the data held in state, so delete it for a gas refund
         */
        delete validationData[id];
    }

    /* Private Functions */

    /**
     * @notice Deterministically generates a seed from the block hash at the block number of creation of the validation
     * data plus MAXIMUM_NUM_SIGNERS
     * @dev Note that `blockhash(blockNum)` will only work for the 256 most recent blocks. If
     * `completeSignatureCommitment` is called too late, a new call to `newSignatureCommitment` is necessary to reset
     * validation data's block number
     * @param data a storage reference to the validationData struct
     * @return onChainRandNums an array storing the random numbers generated inside this function
     */
    function getSeed(ValidationData storage data)
        private
        view
        returns (uint256)
    {
        // @note Get payload.blocknumber, add BLOCK_WAIT_PERIOD
        uint256 randomSeedBlockNum = data.blockNumber + BLOCK_WAIT_PERIOD;
        // @note Create a hash seed from the block number
        bytes32 randomSeedBlockHash = blockhash(randomSeedBlockNum);

        return uint256(randomSeedBlockHash);
    }

    function verifyNewestMMRLeaf(
        BeefyMMRLeaf calldata leaf,
        bytes32[] calldata proof,
        bytes32 root,
        uint64 length
    ) internal {
        bytes memory encodedLeaf = encodeMMRLeaf(leaf);
        bytes32 hashedLeaf = hashMMRLeaf(encodedLeaf);

        mmrVerification.verifyInclusionProof(
            root,
            hashedLeaf,
            length - 1,
            length,
            proof
        );
    }

    /**
     * @notice Perform some operation[s] using the payload
     * @param payload The payload variable passed in via the initial function
     */
    function processPayload(bytes32 payload, uint64 blockNumber) private {
        // Check the payload is newer than the latest
        // Check that payload.leaf.block_number is > last_known_block_number;

        // if payload is not in current or next epoch, reject

        latestMMRRoot = payload;
        emit NewMMRRoot(latestMMRRoot, blockNumber);

        // if payload is in next epoch, then apply validatorset changes

        applyValidatorSetChanges(payload);
    }

    /**
     * @notice Check if the payload includes a new validator set,
     * and if it does then update the new validator set
     * @dev This function should call out to the validator registry contract
     * @param payload The value to check if changes are required
     */
    function applyValidatorSetChanges(bytes32 payload) private {
        // @todo Implement this function
        // payload should contain a new root AND a MMR proof to the newest leaf
        // check proof is for the newest leaf and is valid
        // in the new leaf we should have
        /*
        		MmrLeaf {
            block_number: int
			parent_hash: frame_system::Module::<T>::leaf_data(),
			parachain_heads: Module::<T>::parachain_heads_merkle_root(),
			beefy_authority_set: Module::<T>::beefy_authority_set_merkle_root(),
		}
        */
        // get beefy_authority_set from newest leaf
        // update authority set
        // validatorRegistry.updateValidatorSet(beefy_authority_set)
    }

    function requiredNumberOfSignatures() public view returns (uint256) {
        return
            (validatorRegistry.numOfValidators() *
                THRESHOLD_NUMERATOR +
                THRESHOLD_DENOMINATOR -
                1) / THRESHOLD_DENOMINATOR;
    }

    function verifyCommitment(
        uint256 id,
        Commitment calldata commitment,
        ValidatorProof calldata proof
    ) internal view {
        ValidationData storage data = validationData[id];

        /**
         * @dev verify that sender is the same as in `newSignatureCommitment`
         */
        require(
            msg.sender == data.senderAddress,
            "Error: Sender address does not match original validation data"
        );

        uint256 requiredNumOfSignatures = requiredNumberOfSignatures();

        /**
         * @dev verify that block wait period has passed
         */
        require(
            block.number >= data.blockNumber + BLOCK_WAIT_PERIOD,
            "Error: Block wait period not over"
        );

        uint256[] memory randomBitfield =
            Bitfield.randomNBitsWithPriorCheck(
                getSeed(data),
                data.validatorClaimsBitfield,
                requiredNumOfSignatures
            );

        verifyValidatorProofLengths(requiredNumOfSignatures, proof);

        verifyValidatorProofSignatures(
            randomBitfield,
            proof,
            requiredNumOfSignatures,
            commitment
        );
    }

    function verifyValidatorProofLengths(
        uint256 requiredNumOfSignatures,
        ValidatorProof calldata proof
    ) internal pure {
        /**
         * @dev verify that required number of signatures, positions, public keys and merkle proofs are
         * submitted
         */
        require(
            proof.signatures.length == requiredNumOfSignatures,
            "Error: Number of signatures does not match required"
        );
        require(
            proof.positions.length == requiredNumOfSignatures,
            "Error: Number of validator positions does not match required"
        );
        require(
            proof.publicKeys.length == requiredNumOfSignatures,
            "Error: Number of validator public keys does not match required"
        );
        require(
            proof.publicKeyMerkleProofs.length == requiredNumOfSignatures,
            "Error: Number of validator public keys does not match required"
        );
    }

    function verifyValidatorProofSignatures(
        uint256[] memory randomBitfield,
        ValidatorProof calldata proof,
        uint256 requiredNumOfSignatures,
        Commitment calldata commitment
    ) internal view {
        // Encode and hash the commitment
        bytes32 commitmentHash = createCommitmentHash(commitment);

        /**
         *  @dev For each randomSignature, do:
         */
        for (uint256 i = 0; i < requiredNumOfSignatures; i++) {
            verifyValidatorSignature(
                randomBitfield,
                proof.signatures[i],
                proof.positions[i],
                proof.publicKeys[i],
                proof.publicKeyMerkleProofs[i],
                commitmentHash
            );
        }
    }

    function verifyValidatorSignature(
        uint256[] memory randomBitfield,
        bytes calldata signature,
        uint256 position,
        address publicKey,
        bytes32[] calldata publicKeyMerkleProof,
        bytes32 commitmentHash
    ) internal view {
        /**
         * @dev Check if validator in randomBitfield
         */
        require(
            randomBitfield.isSet(position),
            "Error: Validator must be once in bitfield"
        );

        /**
         * @dev Remove validator from randomBitfield such that no validator can appear twice in signatures
         */
        randomBitfield.clear(position);

        /**
         * @dev Check if merkle proof is valid
         */
        require(
            validatorRegistry.checkValidatorInSet(
                publicKey,
                position,
                publicKeyMerkleProof
            ),
            "Error: Validator must be in validator set at correct position"
        );

        /**
         * @dev Check if signature is correct
         */
        require(
            ECDSA.recover(commitmentHash, signature) == publicKey,
            "Error: Invalid Signature"
        );
    }

    function createCommitmentHash(Commitment calldata commitment)
        public
        view
        returns (bytes32)
    {
        return
            blake2b.formatOutput(
                blake2b.blake2b(
                    abi.encodePacked(
                        commitment.payload,
                        commitment.blockNumber.encode64(),
                        commitment.validatorSetId.encode32()
                    ),
                    "",
                    32
                )
            )[0];
    }

    function encodeMMRLeaf(BeefyMMRLeaf calldata leaf)
        public
        view
        returns (bytes memory)
    {
        bytes memory scaleEncodedMMRLeaf =
            abi.encodePacked(
                ScaleCodec.encode32(leaf.parentNumber),
                leaf.parentHash,
                leaf.parachainHeadsRoot,
                ScaleCodec.encode64(leaf.nextAuthoritySetId),
                ScaleCodec.encode32(leaf.nextAuthoritySetLen),
                leaf.nextAuthoritySetRoot
            );

        uint16 length = uint16(scaleEncodedMMRLeaf.length);
        bytes2 lengthEncoded = ScaleCodec.encodeUintCompact(length);

        return bytes.concat(lengthEncoded, scaleEncodedMMRLeaf);
    }

    function hashMMRLeaf(bytes memory leaf) public pure returns (bytes32) {
        return keccak256(leaf);
    }
}
