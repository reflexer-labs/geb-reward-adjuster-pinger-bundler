pragma solidity 0.6.7;

import "ds-test/test.sol";

import { OracleRelayer } from "geb/OracleRelayer.sol";
import { StabilityFeeTreasury } from "geb/StabilityFeeTreasury.sol";
import {Coin} from "geb/Coin.sol";
import "geb/SAFEEngine.sol";
import {CoinJoin} from "geb/BasicTokenAdapters.sol";
import {SFTreasuryCoreParamAdjuster} from "geb-treasury-core-param-adjuster/SFTreasuryCoreParamAdjuster.sol";
import {MandatoryFixedTreasuryReimbursement} from "geb-treasury-reimbursement/reimbursement/single/MandatoryFixedTreasuryReimbursement.sol";
import {IncreasingTreasuryReimbursement} from "geb-treasury-reimbursement/reimbursement/single/IncreasingTreasuryReimbursement.sol";

import {FixedRewardsAdjuster} from "geb-reward-adjuster/FixedRewardsAdjuster.sol";
import {MinMaxRewardsAdjuster} from "geb-reward-adjuster/MinMaxRewardsAdjuster.sol";
import "../RewardAdjusterBundler.sol";

abstract contract Hevm {
    function warp(uint256) virtual public;
}

contract Usr {
    address bundler;

    constructor(address bundler_) public {
        bundler = bundler_;
    }

    function callBundler(bytes memory data) internal {
        (bool success, ) = bundler.call(data);
        if (!success) {
            assembly {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    function modifyParameters(bytes32, address) public { callBundler(msg.data); }
    function modifyParameters(bytes32, uint, uint, bytes4, address) public { callBundler(msg.data); }
    function recomputeAllRewards() public { callBundler(msg.data); }
}

contract Feed {
    uint price;

    constructor (uint price_) public {
        price = price_;
    }

    function read() public view returns (uint) {
        return price;
    }
}

contract FixedTreasuryFundable is MandatoryFixedTreasuryReimbursement {

    constructor(
        address treasury,
        uint reward
    ) public MandatoryFixedTreasuryReimbursement (
        treasury,
        reward
    ) {}

    function modifyParameters(bytes32 param, uint val) public {
        if (param == "fixedReward") fixedReward = val;
        else revert("unrecognized param");
    }
}

contract MinMaxTreasuryFundable is IncreasingTreasuryReimbursement {

    constructor(
        address treasury
    ) public IncreasingTreasuryReimbursement (
        treasury,
        1 ether,
        2 ether,
        10**27
    ) {}

    function modifyParameters(bytes32 param, uint val) public {
        if (param == "maxUpdateCallerReward") maxUpdateCallerReward = val;
        else if (param == "baseUpdateCallerReward") baseUpdateCallerReward = val;
        else revert("unrecognized param");
    }
}

contract RewardAdjusterBundlerTest is DSTest {
    Hevm hevm;

    FixedRewardsAdjuster fixedAdjuster;
    MinMaxRewardsAdjuster minMaxAdjuster;
    StabilityFeeTreasury treasury;
    OracleRelayer oracleRelayer;
    Feed ethPriceOracle;
    Feed gasPriceOracle;
    SAFEEngine safeEngine;
    Coin systemCoin;
    CoinJoin systemCoinA;
    SFTreasuryCoreParamAdjuster treasuryParamAdjuster;
    FixedTreasuryFundable fixedTreasuryFundable;
    MinMaxTreasuryFundable minMaxTreasuryFundable;
    Usr usr;

    uint256 public updateDelay = 1 days;
    uint256 public lastUpdateTime = 604411201;
    uint256 public treasuryCapacityMultiplier = 100;
    uint256 public minTreasuryCapacity = 1000 ether;
    uint256 public minimumFundsMultiplier = 100;
    uint256 public minMinimumFunds = 1 ether;
    uint256 public pullFundsMinThresholdMultiplier = 100;
    uint256 public minPullFundsThreshold = 2 ether;

    uint256 public constant WAD            = 10**18;
    uint256 public constant RAY            = 10**27;

    FixedRewardsAdjuster fixedRewardAdjuster;
    MinMaxRewardsAdjuster minMaxRewardAdjuster;
    RewardAdjusterBundler bundler;
    uint maxFunctions = 10;

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        safeEngine  = new SAFEEngine();
        systemCoin = new Coin("Coin", "COIN", 99);
        systemCoinA = new CoinJoin(address(safeEngine), address(systemCoin));
        treasury = new StabilityFeeTreasury(address(safeEngine), address(0x1), address(systemCoinA));
        oracleRelayer = new OracleRelayer(address(safeEngine));
        ethPriceOracle = new Feed(1000 ether);
        gasPriceOracle = new Feed(100 * 10**9); // 100 gwei
        fixedTreasuryFundable = new FixedTreasuryFundable(address(treasury), 1 ether);
        minMaxTreasuryFundable = new MinMaxTreasuryFundable(address(treasury));

        treasuryParamAdjuster = new SFTreasuryCoreParamAdjuster(
            address(treasury),
            updateDelay,
            lastUpdateTime,
            treasuryCapacityMultiplier,
            minTreasuryCapacity,
            minimumFundsMultiplier,
            minMinimumFunds,
            pullFundsMinThresholdMultiplier,
            minPullFundsThreshold
        );

        treasury.addAuthorization(address(treasuryParamAdjuster));

        fixedAdjuster = new FixedRewardsAdjuster(
            address(oracleRelayer),
            address(treasury),
            address(gasPriceOracle),
            address(ethPriceOracle),
            address(treasuryParamAdjuster)
        );

        minMaxAdjuster = new MinMaxRewardsAdjuster(
            address(oracleRelayer),
            address(treasury),
            address(gasPriceOracle),
            address(ethPriceOracle),
            address(treasuryParamAdjuster)
        );

        treasuryParamAdjuster.addRewardAdjuster(address(fixedAdjuster));
        treasury.addAuthorization(address(fixedAdjuster));
        treasuryParamAdjuster.addRewardAdjuster(address(minMaxAdjuster));
        treasury.addAuthorization(address(minMaxAdjuster));

        bundler = new RewardAdjusterBundler(
            address(fixedAdjuster),
            address(minMaxAdjuster),
            maxFunctions
        );

        usr = new Usr(address(bundler));
    }

    function test_setup() public {
        assertEq(bundler.authorizedAccounts(address(this)), 1);
        assertEq(bundler.maxFunctions(), maxFunctions);
        assertEq(address(bundler.fixedRewardAdjuster()), address(fixedAdjuster));
        assertEq(address(bundler.minMaxRewardAdjuster()), address(minMaxAdjuster));
    }

    function testFail_setup_null_max_functions() public {
        bundler = new RewardAdjusterBundler(
            address(fixedAdjuster),
            address(minMaxAdjuster),
            0
        );
    }

    function testFail_setup_null_fixed_adjuster() public {
        bundler = new RewardAdjusterBundler(
            address(0),
            address(minMaxAdjuster),
            maxFunctions
        );
    }

    function testFail_setup_null_minmax_adjuster() public {
        bundler = new RewardAdjusterBundler(
            address(fixedAdjuster),
            address(0),
            maxFunctions
        );
    }

    function test_modify_parameters_address() public {
        bundler.modifyParameters("fixedRewardAdjuster", address(0x123));
        assertEq(address(bundler.fixedRewardAdjuster()), address(0x123));

        bundler.modifyParameters("minMaxRewardAdjuster", address(0x1234));
        assertEq(address(bundler.minMaxRewardAdjuster()), address(0x1234));
    }

    function testFail_modify_parameters_address_null() public {
        bundler.modifyParameters("fixedRewardAdjuster", address(0x0));
    }

    function testFail_modify_parameters_invalid_param() public {
        bundler.modifyParameters("invalid", address(0x1));
    }

    function testFail_modify_parameters_address_unauthorized() public {
        usr.modifyParameters("fixedRewardAdjuster", address(0x123));
    }

    function test_add_funded_function() public {
        assertEq(bundler.fundedFunctionsAmount(), 0);

        bundler.modifyParameters(
            "addFunction",
            0, // position, irrelevant when adding
            1, // type
            bytes4("0x22"),
            address(0x22)
        );

        assertEq(bundler.addedFunction(address(0x22), bytes4("0x22")), 1);
        assertEq(bundler.fundedFunctionNonce(), 1);
        assertEq(bundler.latestFundedFunction(), 1);
        (uint adjusterType, bytes4 functionSig, address receiverContract) = bundler.fundedFunctions(1);
        assertEq(adjusterType, 1);
        assertEq(functionSig, bytes4("0x22"));
        assertEq(receiverContract, address(0x22));
        assertEq(bundler.fundedFunctionsAmount(), 1);
        assertTrue(bundler.isFundedFunction(1));
    }

    function testFail_add_funded_function_null_receiver_contract() public {
        bundler.modifyParameters(
            "addFunction",
            0, // position, irrelevant when adding
            0, // type
            bytes4("0x22"),
            address(0)
        );
    }

    function testFail_add_funded_function_invalid_adjuster_type() public {
        bundler.modifyParameters(
            "addFunction",
            0, // position, irrelevant when adding
            2, // type
            bytes4("0x22"),
            address(0x22)
        );
    }

    function testFail_add_funded_function_already_added() public {
        test_add_funded_function();
        bundler.modifyParameters(
            "addFunction",
            0, // position, irrelevant when adding
            0, // type
            bytes4("0x22"),
            address(0x22)
        );
    }

    function testFail_add_funded_function_over_max_functions() public {
        bundler = new RewardAdjusterBundler(
            address(fixedAdjuster),
            address(minMaxAdjuster),
            1
        );

        test_add_funded_function();
        bundler.modifyParameters(
            "addFunction",
            0, // position, irrelevant when adding
            0, // type
            bytes4("0x21"),
            address(0x21)
        );
    }

    function testFail_add_funded_function_invalid_param() public {
        bundler.modifyParameters(
            "invalid",
            0, // position
            0, // type
            bytes4("0x21"),
            address(0x21)
        );
    }

    function test_remove_funded_function() public {
        test_add_funded_function();
        bundler.modifyParameters(
            "removeFunction",
            1,              // position
            0,              // type, irrelevant for this call
            bytes4("0x22"), // sig, irrelevant for this call
            address(0x22)   // receiver, irrelevant for this call
        );

        assertEq(bundler.addedFunction(address(0x22), bytes4("0x22")), 0);
        assertEq(bundler.fundedFunctionNonce(), 1);
        assertEq(bundler.latestFundedFunction(), 0);
        (uint adjusterType, bytes4 functionSig, address receiverContract) = bundler.fundedFunctions(1);
        assertEq(adjusterType, 0);
        assertEq(functionSig, bytes4(0));
        assertEq(receiverContract, address(0));
        assertEq(bundler.fundedFunctionsAmount(), 0);
        assertTrue(!bundler.isFundedFunction(1));
    }

    function testFail_remove_funded_function_unexisting() public {
        test_add_funded_function();
        bundler.modifyParameters(
            "removeFunction",
            2,              // position
            0,              // type, irrelevant for this call
            bytes4("0x22"), // sig, irrelevant for this call
            address(0x22)   // receiver, irrelevant for this call
        );
    }

    function testFail_remove_funded_null_position() public {
        test_add_funded_function();
        bundler.modifyParameters(
            "removeFunction",
            0,              // position
            0,              // type, irrelevant for this call
            bytes4("0x22"), // sig, irrelevant for this call
            address(0x22)   // receiver, irrelevant for this call
        );
    }

    function testFail_remove_funded_function_previously_existing_removed() public {
        test_add_funded_function();
        bundler.modifyParameters(
            "removeFunction",
            1,              // position
            0,              // type, irrelevant for this call
            bytes4("0x22"), // sig, irrelevant for this call
            address(0x22)   // receiver, irrelevant for this call
        );

        bundler.modifyParameters(
            "removeFunction",
            1,              // position
            0,              // type, irrelevant for this call
            bytes4("0x22"), // sig, irrelevant for this call
            address(0x22)   // receiver, irrelevant for this call
        );
    }

    function testFail_add_remove_funded_function_unauthed() public {
        test_add_funded_function();
        usr.modifyParameters(
            "removeFunction",
            1,              // position
            0,              // type, irrelevant for this call
            bytes4("0x22"), // sig, irrelevant for this call
            address(0x22)   // receiver, irrelevant for this call
        );
    }

    function test_recompute_all_rewards() public {

        // fixed
        bundler.modifyParameters(
            "addFunction",
            0, // position, irrelevant when adding
            0, // type: fixed
            bytes4("0x22"),
            address(fixedTreasuryFundable)
        );
        fixedAdjuster.addFundingReceiver(address(fixedTreasuryFundable), bytes4("0x22"), 1 days, 10**6, 100);
        treasuryParamAdjuster.addFundedFunction(address(fixedTreasuryFundable), bytes4("0x22"), 1);

        // minmax
        bundler.modifyParameters(
            "addFunction",
            0, // position, irrelevant when adding
            1, // type: minMax
            bytes4("0x33"),
            address(minMaxTreasuryFundable)
        );
        minMaxAdjuster.addFundingReceiver(address(minMaxTreasuryFundable), bytes4("0x33"), 1 days, 10**6, 100, 101);
        treasuryParamAdjuster.addFundedFunction(address(minMaxTreasuryFundable), bytes4("0x33"), 1);

        hevm.warp(now + 1 days);

        // recomputing
        usr.recomputeAllRewards();

        // tests, fixed
        (
        uint lastUpdateTime_,
        uint gasAmountForExecution,
        uint updateDelay_,
        uint fixedRewardMultiplier
        ) = fixedAdjuster.fundingReceivers(address(fixedTreasuryFundable), bytes4("0x22"));

        assertEq(lastUpdateTime_, now);
        assertEq(gasAmountForExecution, 10**6);
        assertEq(updateDelay_, 1 days);
        assertEq(fixedRewardMultiplier, 100);

        uint fixedRewardDenominatedValue = gasPriceOracle.read() * gasAmountForExecution * WAD / ethPriceOracle.read();
        uint newFixedReward = (fixedRewardDenominatedValue * RAY / oracleRelayer.redemptionPrice()) * fixedRewardMultiplier / 100;

        assertEq(fixedTreasuryFundable.fixedReward(), newFixedReward);

        (, uint perBlockAllownace) = treasury.getAllowance(address(fixedTreasuryFundable));
        assertEq(perBlockAllownace, newFixedReward * RAY);

        (, uint latestMaxReward) = treasuryParamAdjuster.whitelistedFundedFunctions(address(fixedTreasuryFundable), bytes4("0x22"));
        assertEq(latestMaxReward, newFixedReward);

        // tests, minmax
        uint baseRewardMultiplier;
        uint maxRewardMultiplier;

        (
            lastUpdateTime_,
            gasAmountForExecution,
            updateDelay_,
            baseRewardMultiplier,
            maxRewardMultiplier
        ) = minMaxAdjuster.fundingReceivers(address(minMaxTreasuryFundable), bytes4("0x33"));

        assertEq(lastUpdateTime_, now);
        assertEq(gasAmountForExecution, 10**6);
        assertEq(updateDelay_, 1 days);
        assertEq(baseRewardMultiplier, 100);
        assertEq(maxRewardMultiplier, 101);

        uint baseRewardFiatValue = gasPriceOracle.read() * gasAmountForExecution * WAD / ethPriceOracle.read();
        uint newBaseReward = (baseRewardFiatValue * RAY / oracleRelayer.redemptionPrice()) * baseRewardMultiplier / 100;
        uint newMaxReward = newBaseReward * maxRewardMultiplier / 100;

        assertEq(minMaxTreasuryFundable.baseUpdateCallerReward(), newBaseReward);
        assertEq(minMaxTreasuryFundable.maxUpdateCallerReward(), newMaxReward);

        (, perBlockAllownace) = treasury.getAllowance(address(minMaxTreasuryFundable));
        assertEq(perBlockAllownace, newMaxReward * RAY);

        (, latestMaxReward) = treasuryParamAdjuster.whitelistedFundedFunctions(address(minMaxTreasuryFundable), bytes4("0x33"));
        assertEq(latestMaxReward, newMaxReward);
    }

    function test_recompute_all_rewards_one_failing() public {

        // fixed, will fail due to not being setup in the adjuster and treasury param adjuster
        bundler.modifyParameters(
            "addFunction",
            0, // position, irrelevant when adding
            0, // type: fixed
            bytes4("0x22"),
            address(fixedTreasuryFundable)
        );

        // minmax
        bundler.modifyParameters(
            "addFunction",
            0, // position, irrelevant when adding
            1, // type: minMax
            bytes4("0x33"),
            address(minMaxTreasuryFundable)
        );
        minMaxAdjuster.addFundingReceiver(address(minMaxTreasuryFundable), bytes4("0x33"), 1 days, 10**6, 100, 101);
        treasuryParamAdjuster.addFundedFunction(address(minMaxTreasuryFundable), bytes4("0x33"), 1);

        hevm.warp(now + 1 days);

        // recomputing
        bundler.recomputeAllRewards();

        // tests, minmax
        (
            uint lastUpdateTime_,
            uint gasAmountForExecution,
            uint updateDelay_,
            uint baseRewardMultiplier,
            uint maxRewardMultiplier
        ) = minMaxAdjuster.fundingReceivers(address(minMaxTreasuryFundable), bytes4("0x33"));

        assertEq(lastUpdateTime_, now);
        assertEq(gasAmountForExecution, 10**6);
        assertEq(updateDelay_, 1 days);
        assertEq(baseRewardMultiplier, 100);
        assertEq(maxRewardMultiplier, 101);

        uint baseRewardFiatValue = gasPriceOracle.read() * gasAmountForExecution * WAD / ethPriceOracle.read();
        uint newBaseReward = (baseRewardFiatValue * RAY / oracleRelayer.redemptionPrice()) * baseRewardMultiplier / 100;
        uint newMaxReward = newBaseReward * maxRewardMultiplier / 100;

        assertEq(minMaxTreasuryFundable.baseUpdateCallerReward(), newBaseReward);
        assertEq(minMaxTreasuryFundable.maxUpdateCallerReward(), newMaxReward);

        (, uint perBlockAllownace) = treasury.getAllowance(address(minMaxTreasuryFundable));
        assertEq(perBlockAllownace, newMaxReward * RAY);

        (, uint latestMaxReward) = treasuryParamAdjuster.whitelistedFundedFunctions(address(minMaxTreasuryFundable), bytes4("0x33"));
        assertEq(latestMaxReward, newMaxReward);
    }
}