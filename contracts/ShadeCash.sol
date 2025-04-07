pragma solidity 0.5.17;

import "./MerkleTreeWithHistory.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import '@openzeppelin/contracts/math/SafeMath.sol';

contract IVerifier {
  function verifyProof(bytes memory _proof, uint256[6] memory _input) public returns(bool);
}

contract ShadeCash is MerkleTreeWithHistory, ReentrancyGuard {
  using SafeMath for uint256;
  
  uint256 public denomination;
  mapping(bytes32 => bool) public nullifierHashes;
  // we store all commitments just to prevent accidental deposits with the same commitment
  mapping(bytes32 => bool) public commitments;
  IVerifier public verifier;

  // Tax percent multiplied by 100
  uint256 public constant maxTaxPercent = 1000; // = 10 
  uint256 public taxPercent = 0; // 10 = 0,1%, 100 = 1%, 1000 = 10%, 255 = 2,55%
  
  // Info of each user that deposit tokens.
  struct Recipient {
    address payable recipient;
    uint256 allocPoint;      
  }
  Recipient[] public taxRecipients;
  uint256 public constant maxAllocPoint = 1000;
  uint256 public totalAllocPoint = 0;

  // operator can update snark verification key
  // after the final trusted setup ceremony operator rights are supposed to be transferred to zero address
  address public operator;
  modifier onlyOperator {
    require(msg.sender == operator, "ShadeCash withdraw: Only operator can call this function.");
    _;
  }

  event Deposit(bytes32 indexed commitment, uint32 leafIndex, uint256 timestamp);
  event Withdrawal(address to, bytes32 nullifierHash, address indexed relayer, uint256 fee);

  /**
    @dev The constructor
    @param _verifier the address of SNARK verifier for this contract
    @param _denomination transfer amount for each deposit
    @param _merkleTreeHeight the height of deposits' Merkle Tree
    @param _operator operator address (see operator comment above)    
  */
  constructor(
    IVerifier _verifier,
    uint256 _denomination,
    uint32 _merkleTreeHeight,
    address _operator    
  ) MerkleTreeWithHistory(_merkleTreeHeight) public {
    require(_denomination > 0, "ShadeCash constructor: Denomination should be greater than 0");
    verifier = _verifier;
    operator = _operator;
    denomination = _denomination;
  }

  /**
    @dev Deposit funds into the contract. The caller must send (for BNB) or approve (for BEP20) value equal to or `denomination` of this instance.
    @param _commitment the note commitment, which is PedersenHash(nullifier + secret)
  */
  function deposit(bytes32 _commitment) external payable nonReentrant {
    require(!commitments[_commitment], "ShadeCash deposit: The commitment has been submitted");

    uint32 insertedIndex = _insert(_commitment);
    commitments[_commitment] = true;
    _processDeposit();

    emit Deposit(_commitment, insertedIndex, block.timestamp);
  }

  /** @dev this function is defined in a child contract */
  function _processDeposit() internal;

  /**
    @dev Withdraw a deposit from the contract. `proof` is a zkSNARK proof data, and input is an array of circuit public inputs
    `input` array consists of:
      - merkle root of all deposits in the contract
      - hash of unique deposit nullifier to prevent double spends
      - the recipient of funds
      - optional fee that goes to the transaction sender (usually a relay)
  */
  function withdraw(bytes calldata _proof, bytes32 _root, bytes32 _nullifierHash, address payable _recipient, address payable _relayer, uint256 _fee, uint256 _refund) external payable nonReentrant {
    require(_fee <= denomination, "ShadeCash withdraw: Fee exceeds transfer value");
    require(!nullifierHashes[_nullifierHash], "ShadeCash withdraw: The note has been already spent");
    require(isKnownRoot(_root), "ShadeCash withdraw: Cannot find your merkle root"); // Make sure to use a recent one
    require(verifier.verifyProof(_proof, [uint256(_root), uint256(_nullifierHash), uint256(_recipient), uint256(_relayer), _fee, _refund]), "ShadeCash::withdraw: Invalid withdraw proof");

    nullifierHashes[_nullifierHash] = true;
    _processWithdraw(_recipient, _relayer, _fee, _refund);
    emit Withdrawal(_recipient, _nullifierHash, _relayer, _fee);
  }

  /** @dev this function is defined in a child contract */
  function _processWithdraw(address payable _recipient, address payable _relayer, uint256 _fee, uint256 _refund) internal;

  /** @dev whether a note is already spent */
  function isSpent(bytes32 _nullifierHash) public view returns(bool) {
    return nullifierHashes[_nullifierHash];
  }

  /** @dev whether an array of notes is already spent */
  function isSpentArray(bytes32[] calldata _nullifierHashes) external view returns(bool[] memory spent) {
    spent = new bool[](_nullifierHashes.length);
    for(uint i = 0; i < _nullifierHashes.length; i++) {
      if (isSpent(_nullifierHashes[i])) {
        spent[i] = true;
      }
    }
  }

  /**
    @dev allow operator to update SNARK verification keys. This is needed to update keys after the final trusted setup ceremony is held.
    After that operator rights are supposed to be transferred to zero address
  */
  function updateVerifier(address _newVerifier) external onlyOperator {
    verifier = IVerifier(_newVerifier);
  }

  /** @dev operator can change his address */
  function changeOperator(address _newOperator) external onlyOperator {
    operator = _newOperator;
  }

  // Deposit tokens
  function setTaxPercent(uint256 _taxPercent) external onlyOperator {    
    require(_taxPercent <= maxTaxPercent, "ShadeCash setTaxPercent: Shold be from 0 to maxTaxPercent");    
    taxPercent = _taxPercent;
  }

  // Add recipient
  function addRecipient(address payable _recipient, uint256 _allocPoint) external onlyOperator {
    require(_allocPoint <= maxAllocPoint, "ShadeCash addRecipient: Shold be from 0 to maxAllocPoint");
        
    for (uint256 _index = 0; _index < taxRecipients.length; _index++) {
      require(taxRecipients[_index].recipient != _recipient, "ShadeCash addRecipient: Recipient already exists");
    }

    totalAllocPoint = totalAllocPoint.add(_allocPoint);
    taxRecipients.push(Recipient({
      recipient: _recipient,
      allocPoint: _allocPoint        
    }));
  }
  
  // Remove recipient At Index
  function removeRecipientAtIndex(uint256 _index) external onlyOperator {
    require(taxRecipients.length > 0, "ShadeCash removeRecipientAtIndex: No recipients");
    require(_index < taxRecipients.length, "ShadeCash removeRecipientAtIndex: No such index");
    
    totalAllocPoint = totalAllocPoint.sub(taxRecipients[_index].allocPoint);
        
    for (uint i = _index; i < taxRecipients.length - 1; i ++){
      taxRecipients[i] = taxRecipients[i+1];
    }
    taxRecipients.pop(); 
  }

  // Set recipient Alloc Point At Index
  function setRecipientAllocPointAtIndex(uint256 _index, uint256 _allocPoint) external onlyOperator {
    require(_index < taxRecipients.length, "ShadeCash setRecipientAllocPointAtIndex: No such index");
    require(_allocPoint <= maxAllocPoint, "ShadeCash setRecipientAllocPointAtIndex: Shold be from 0 to maxAllocPoint");
    
    totalAllocPoint = totalAllocPoint.sub(taxRecipients[_index].allocPoint).add(_allocPoint);
    
    taxRecipients[_index].allocPoint = _allocPoint;        
  }
}