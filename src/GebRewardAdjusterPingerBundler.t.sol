pragma solidity ^0.8.6;

import "ds-test/test.sol";

import "./GebRewardAdjusterPingerBundler.sol";

contract GebRewardAdjusterPingerBundlerTest is DSTest {
    GebRewardAdjusterPingerBundler bundler;

    function setUp() public {
        bundler = new GebRewardAdjusterPingerBundler();
    }

    function testFail_basic_sanity() public {
        assertTrue(false);
    }

    function test_basic_sanity() public {
        assertTrue(true);
    }
}
