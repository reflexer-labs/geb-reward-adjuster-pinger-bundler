pragma solidity 0.6.7;

import "./LinkedList.sol";

abstract contract RewardAdjusterLike {
    function recomputeRewards(address, bytes4) external virtual;
}

contract RewardAdjusterBundler {
    using LinkedList for LinkedList.List;

    // --- Auth ---
    mapping (address => uint256) public authorizedAccounts;
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) external isAuthorized {
        authorizedAccounts[account] = 1;
        emit AddAuthorization(account);
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) external isAuthorized {
        authorizedAccounts[account] = 0;
        emit RemoveAuthorization(account);
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "RewardAdjusterBundler/account-not-authorized");
        _;
    }

    // --- Variables ---
    // Number of funded functions ever added
    uint256            public fundedFunctionNonce;
    // Max number of functions that can be in the list
    uint256            public maxFunctions;
    // Latest funded function index in the list
    uint256            public latestFundedFunction;

    // Mapping with functions that were already added
    mapping(address => mapping(bytes4 => uint256)) public addedFunction;
    // Data about each funded function
    mapping(uint256 => FundedFunction)             public fundedFunctions;

    // Linked list with functions offering rewards to be called
    LinkedList.List    internal fundedFunctionsList;

    // The fixed reward adjuster
    RewardAdjusterLike public fixedRewardAdjuster;
    // The min + max reward adjuster
    RewardAdjusterLike public minMaxRewardAdjuster;

    // --- Structs ---
    struct FundedFunction {
        uint256 adjusterType;
        bytes4  functionName;
        address receiverContract;
    }

    // --- Events ---
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event FailedRecomputeReward(uint256 adjusterType, address receiverContract, bytes4 functionName);
    event AddFundedFunction(
      uint256 latestFundedFunction,
      uint256 adjusterType,
      bytes4 functionName,
      address receiverContract
    );
    event RemoveFundedFunction(uint256 functionPosition);
    event ModifyParameters(bytes32 parameter, address val);
    event ModifyParameters(bytes32 actionType, uint256 functionPosition, uint256 adjusterType, bytes4 functionName, address receiverContract);

    constructor(address _fixedRewardAdjuster, address _minMaxRewardAdjuster, uint256 _maxFunctions) public {
        require(_maxFunctions > 0, "RewardAdjusterBundler/null-max-functions");
        require(_fixedRewardAdjuster != address(0), "RewardAdjusterBundler/null-fixed-reward-adjuster");
        require(_minMaxRewardAdjuster != address(0), "RewardAdjusterBundler/null-minmax-reward-adjuster");

        authorizedAccounts[msg.sender] = 1;
        maxFunctions                   = _maxFunctions;

        fixedRewardAdjuster            = RewardAdjusterLike(_fixedRewardAdjuster);
        minMaxRewardAdjuster           = RewardAdjusterLike(_minMaxRewardAdjuster);

        emit AddAuthorization(msg.sender);
    }

    // --- Boolean Logic ---
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    // --- Math ---
    function addition(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x + y;
        require(z >= x, "RewardAdjusterBundler/add-uint-uint-overflow");
    }
    function subtract(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x, "RewardAdjusterBundler/sub-uint-uint-underflow");
    }

    // --- Administration ---
    /*
     * @notice Modify address params
     * @param parameter The name of the parameter to update
     * @param val The new address for the parameter
     */
    function modifyParameters(bytes32 parameter, address val) external isAuthorized {
        require(val != address(0), "RewardAdjusterBundler/null-val");

        if (parameter == "fixedRewardAdjuster") {
          fixedRewardAdjuster = RewardAdjusterLike(val);
        } else if (parameter == "minMaxRewardAdjuster") {
          minMaxRewardAdjuster = RewardAdjusterLike(val);
        } else revert("RewardAdjusterBundler/modify-unrecognized-param");

        emit ModifyParameters(parameter, val);
    }
    /*
     * @notice Add or remove a funded function
     * @param actionType The type of action to execute
     * @param functionPosition The position of the funded function in fundedFunctions
     * @param adjusterType The adjuster contract to include for the funded function
     * @param functionName The signature of the function that gets funded
     * @param receiverContract The contract hosting the funded function
     */
    function modifyParameters(bytes32 actionType, uint256 functionPosition, uint256 adjusterType, bytes4 functionName, address receiverContract)
      external isAuthorized {
        if (actionType == "addFunction") {
          addFundedFunction(adjusterType, functionName, receiverContract);
        } else if (actionType == "removeFunction") {
          removeFundedFunction(functionPosition);
        }
        else revert("RewardAdjusterBundler/modify-unrecognized-param");

        emit ModifyParameters(actionType, functionPosition, adjusterType, functionName, receiverContract);
    }

    // --- Internal Logic ---
    /*
     * @notice Add a funded function
     * @param adjusterType The type of adjuster that recomputes the rewards offered by this function
     * @param functionName The name of the function offering rewards
     * @param receiverContract Contract that has the funded function
     */
    function addFundedFunction(uint256 adjusterType, bytes4 functionName, address receiverContract) internal {
        require(receiverContract != address(0), "RewardAdjusterBundler/null-receiver-contract");
        require(adjusterType <= 1, "RewardAdjusterBundler/invalid-adjuster-type");
        require(addedFunction[receiverContract][functionName] == 0, "RewardAdjusterBundler/function-already-added");
        require(fundedFunctionsAmount() < maxFunctions, "RewardAdjusterBundler/function-limit-reached");

        addedFunction[receiverContract][functionName] = 1;
        fundedFunctionNonce                           = addition(fundedFunctionNonce, 1);
        latestFundedFunction                          = fundedFunctionNonce;
        fundedFunctions[fundedFunctionNonce]          = FundedFunction(adjusterType, functionName, receiverContract);

        fundedFunctionsList.push(latestFundedFunction, false);

        emit AddFundedFunction(
          latestFundedFunction,
          adjusterType,
          functionName,
          receiverContract
        );
    }
    /*
     * @notice Remove a funded function
     * @param functionPosition The position of the funded function in fundedFunctions
     */
    function removeFundedFunction(uint256 functionPosition) internal {
        require(both(functionPosition <= latestFundedFunction, functionPosition > 0), "RewardAdjusterBundler/invalid-position");
        FundedFunction memory fundedFunction = fundedFunctions[functionPosition];

        require(addedFunction[fundedFunction.receiverContract][fundedFunction.functionName] == 1, "RewardAdjusterBundler/function-not-added");
        delete(addedFunction[fundedFunction.receiverContract][fundedFunction.functionName]);

        if (functionPosition == latestFundedFunction) {
          (, uint256 prevReceiver) = fundedFunctionsList.prev(latestFundedFunction);
          latestFundedFunction     = prevReceiver;
        }

        fundedFunctionsList.del(functionPosition);
        delete(fundedFunctions[functionPosition]);

        emit RemoveFundedFunction(functionPosition);
    }

    // --- Core Logic ---
    /*
     * @param Recopute all system coin rewards for all funded functions included in this contract
     */
    function recomputeAllRewards() external {
        // Start looping from the latest funded function
        uint256 currentFundedFunction = latestFundedFunction;

        FundedFunction memory fundedFunction;

        // While we still haven't gone through the entire list
        while (currentFundedFunction > 0) {
          fundedFunction = fundedFunctions[currentFundedFunction];
          if (fundedFunction.adjusterType == 0) {
            try fixedRewardAdjuster.recomputeRewards(fundedFunction.receiverContract, fundedFunction.functionName) {}
            catch(bytes memory /* revertReason */) {
              emit FailedRecomputeReward(fundedFunction.adjusterType, fundedFunction.receiverContract, fundedFunction.functionName);
            }
          } else {
            try minMaxRewardAdjuster.recomputeRewards(fundedFunction.receiverContract, fundedFunction.functionName) {}
            catch(bytes memory /* revertReason */) {
              emit FailedRecomputeReward(fundedFunction.adjusterType, fundedFunction.receiverContract, fundedFunction.functionName);
            }
          }
          // Continue looping
          (, currentFundedFunction) = fundedFunctionsList.prev(currentFundedFunction);
        }
    }

    // --- Getters ---
    /**
     * @notice Get the secondary tax receiver list length
     */
    function fundedFunctionsAmount() public view returns (uint256) {
        return fundedFunctionsList.range();
    }
    /**
     * @notice Check if a funded function index is in the list
     */
    function isFundedFunction(uint256 _fundedFunction) public view returns (bool) {
        if (_fundedFunction == 0) return false;
        return fundedFunctionsList.isNode(_fundedFunction);
    }
}
