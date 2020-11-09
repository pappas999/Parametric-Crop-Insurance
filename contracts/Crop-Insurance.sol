pragma solidity 0.4.24;
pragma experimental ABIEncoderV2;


//Truffle Imports
//import "chainlink/contracts/ChainlinkClient.sol";
//import "chainlink/contracts/vendor/Ownable.sol";
//import "chainlink/contracts/interfaces/LinkTokenInterface.sol";

//Remix imports - used when testing in remix 
import "https://github.com/smartcontractkit/chainlink/blob/develop/evm-contracts/src/v0.4/ChainlinkClient.sol";
import "https://github.com/smartcontractkit/chainlink/blob/develop/evm-contracts/src/v0.4/vendor/Ownable.sol";
import "https://github.com/smartcontractkit/chainlink/blob/develop/evm-contracts/src/v0.4/interfaces/LinkTokenInterface.sol";
import "https://github.com/smartcontractkit/chainlink/blob/develop/evm-contracts/src/v0.4/interfaces/AggregatorInterface.sol";
import "https://github.com/smartcontractkit/chainlink/blob/develop/evm-contracts/src/v0.4/vendor/SafeMathChainlink.sol";



contract InsuranceProvider {
    
    using SafeMathChainlink for uint;
    address public insurer = msg.sender;

    uint public constant DAY_IN_SECONDS = 60; //How many seconds in a day. 60 for testing, 86400 for Production
    
    uint256 constant private ORACLE_PAYMENT = 0.1 * 10**18; // 0.1 LINK
    address public constant LINK_KOVAN = 0x20fE562d797A42Dcb3399062AE9546cd06f63280 ; //address of LINK token on Ropsten
    
    address public constant ORACLE_CONTRACT = 0x4a3fbbb385b5efeb4bc84a25aaadcd644bd09721;
    string public constant JOB_ID = '6e34d8df2b864393a1f6b7e38917706b';
    
        
    //here is where all the insurance contracts are stored.
    mapping (address => InsuranceContract) contracts; 
    
    
    constructor()   public payable {
    }

    /**
     * @dev Prevents a function being run unless it's called by the Insurance Provider
     */
    modifier onlyOwner() {
		require(insurer == msg.sender,'Only Insurance provider can do this');
        _;
    }
    

   /**
    * @dev Event to log when a contract is created
    */    
    event contractCreated(address _insuranceContract, uint _premium, uint _totalCover);
    
    
    /**
     * @dev Create a new contract for client, automatically approved and deployed to the blockchain
     */ 
    function newContract(address _client, uint _duration, uint _premium, uint _payoutValue, string _cropLocation) public payable onlyOwner() returns(address) {
        

        //create contract, send payout amount so contract is fully funded plus a small buffer
        InsuranceContract i = (new InsuranceContract).value(_payoutValue.add(1000000000000000))(_client, _duration, _premium, _payoutValue, _cropLocation,
                                                         LINK_KOVAN, ORACLE_CONTRACT,JOB_ID, ORACLE_PAYMENT);
          
        contracts[address(i)] = i;  //store insurance contract in contracts Map
        
        //emit an event to say the contract has been created and funded
        emit contractCreated(address(i), msg.value, _payoutValue);
        
        //now that contract has been created, we need to fund it with enough LINK tokens to fulfil 1 Oracle request per day, with a small buffer added
        LinkTokenInterface link = LinkTokenInterface(i.getChainlinkToken());
        link.transfer(address(i), ((_duration.div(DAY_IN_SECONDS)) + 2) * ORACLE_PAYMENT);
        
        
        return address(i);
        
    }
    

    /**
     * @dev returns the contract for a given address
     */
    function getContract(address _contract) external view returns (InsuranceContract) {
        return contracts[_contract];
    }
    
    /**
     * @dev Get the insurer address for this insurance provider
     */
    function getInsurer() external view returns (address) {
        return insurer;
    }
    
    /**
     * @dev Get the status of a given Contract
     */
    function getContractStatus(address _address) external view returns (bool) {
        InsuranceContract i = InsuranceContract(_address);
        return i.getContractStatus();
    }
    
    /**
     * @dev Return how much ether is in this master contract
     */
    function getContractBalance() external view returns (uint) {
        return address(this).balance;
    }
    
    /**
     * @dev Function to end provider contract, in case of bugs or needing to update logic etc, funds are returned to insurance provider, including any remaining LINK tokens
     */
    function endContractProvider() external payable onlyOwner() {
        LinkTokenInterface link = LinkTokenInterface(LINK_KOVAN);
        require(link.transfer(msg.sender, link.balanceOf(address(this))), "Unable to transfer");
        selfdestruct(insurer);
    }
    
    /**
     * @dev fallback function, to receive ether
     */
    function() external payable {  }

}

contract InsuranceContract is ChainlinkClient, Ownable  {
    
    using SafeMathChainlink for uint;
    
    uint public constant DAY_IN_SECONDS = 60; //How many seconds in a day. 60 for testing, 86400 for Production
    uint public constant DROUGHT_DAYS_THRESDHOLD = 5;  //Number of consecutive days without rainfall to be defined as a drought
    //uint public constant DROUGHT_RAINFALL_THRESDHOLD = 3;  //3 days above the temp is the trigger for contract conditions to be reached
    uint256 private oraclePaymentAmount;
    string private jobId;

    
    address public insurer;
    address  client;
    uint startDate;
    uint duration;
    uint premium;
    uint payoutValue;
    string cropLocation;
    
    uint256 public index;
    uint256[2] public currentRainfallList;
    
    bytes32[] public jobIds;
    address[] public oracles;
    

    uint daysWithoutRain;                   //how many days there has been with 0 rain
    bool contractActive;                    //is the contract currently active, or has it ended
    bool contractPaid = false;
    uint currentRainfall = 0;               //what is the current rainfall for the location
    uint currentRainfallDateChecked = now + DAY_IN_SECONDS;  //when the last rainfall check was performed
    uint requestCount = 0;                  //how many requests for rainfall data have been made so far for this insurance contract
    

    /**
     * @dev Prevents a function being run unless it's called by Insurance Provider
     */
    modifier onlyOwner() {
		require(insurer == msg.sender,'Only Insurance provider can do this');
        _;
    }
    
    /**
     * @dev Prevents a function being run unless the Insurance Contract duration has been reached
     */
    modifier onContractEnded() {
        if (startDate + duration < now) {
          _;  
        } 
    }
    
    /**
     * @dev Prevents a function being run unless contract is still active
     */
    modifier onContractActive() {
        require(contractActive == true ,'Contract has ended, cant interact with it anymore');
        _;
    }

    /**
     * @dev Prevents a data request to be called unless it's been a day since the last call (to avoid spamming and spoofing results)
     */    
    modifier callFrequencyOncePerDay() {
        require(now - currentRainfallDateChecked > DAY_IN_SECONDS,'Can only check rainfall once per day');
        _;
    }
    
    event contractCreated(address _insurer, address _client, uint _duration, uint _premium, uint _totalCover);
    event contractPaidOut(uint _paidTime, uint _totalPaid, uint _finalRainfall);
    event contractEnded(uint _endTime, uint _totalReturned);
    event ranfallThresholdReset(uint _rainfall);
    event dataRequestSent(bytes32 requestId);
    event dataReceived(uint _rainfall);

    /**
     * @dev Creates a new Insurance contract
     */ 
    constructor(address _client, uint _duration, uint _premium, uint _payoutValue, string _cropLocation, 
                address _link, address _oracle, string _job_id, uint256 _oraclePaymentAmount)  payable Ownable() public {
        
        //initialize variables required for Chainlink Node interaction
        setChainlinkToken(_link);
        setChainlinkOracle(_oracle);
        jobId = _job_id;
        oraclePaymentAmount = _oraclePaymentAmount;
        
        //first ensure insurer has fully funded the contract
        require(msg.value >= _payoutValue, "Not enough funds sent to contract");
        
        //now initialize values for the contract
        insurer= msg.sender;
        client = _client;
        startDate = now + DAY_IN_SECONDS; //contract will be effective from the next day
        duration = _duration;
        premium = _premium;
        payoutValue = _payoutValue;
        daysWithoutRain = 0;
        contractActive = true;
        cropLocation = _cropLocation;
        
        //set the oracles and jodids
        oracles[0] = 0x4a3fbbb385b5efeb4bc84a25aaadcd644bd09721;
        oracles[1] = 0x4a3fbbb385b5efeb4bc84a25aaadcd644bd09721;
        jobIds[0] = '6e34d8df2b864393a1f6b7e38917706b';
        jobIds[1] = '103a6edf984f21086a71a9205dad0c45';
        
        emit contractCreated(insurer,
                             client,
                             duration,
                             premium,
                             payoutValue);
    }
    
    /**
     * @dev Calls out to an Oracle to obtain weather data
     */ 
    function checkContract(address _oracle, bytes32 _jobId) external onContractActive() returns (bytes32 requestId)   {
        //first call end contract in case of insurance contract duration expiring, if it hasn't won't do anything
        endContract();
        
        //contract may have been marked inactive above, only do request if needed
        if (contractActive) {
        
            //get data from the first appid
            Chainlink.Request memory req = buildChainlinkRequest(_jobId, address(this), this.checkContractCallBack.selector);

        
            // Adds an integer with the key "city" to the request parameters, to be used by the Oracle node as a parameter when making a REST request
            //string memory url = string(abi.encodePacked(OPEN_WEATHER_URL, "id=",uint2str(cropLocation),"&appid=",OPEN_WEATHER_KEY));
            //req.add("get", url); //sends the GET request to the oracle
            //req.add("path", "main.temp");  //sends the path to be traversed when the GET returns data
            //req.addInt("times", 100);     //tells the Oracle to * the result by 100 
            
            req.add("q", cropLocation);
            req.add("copyPath","data.current_condition.0.precipMM");
        
            //sends the request to the Oracle Contract which will emit an event that the Oracle Node will pick up and action
            requestId = sendChainlinkRequestTo(chainlinkOracleAddress(), req, oraclePaymentAmount); 
            
            emit dataRequestSent(requestId);
        }
    }
    
    
    /**
     * @dev Callback function - This gets called by the Oracle Contract when the Oracle Node passes data back to the Oracle Contract/
     * The function will take the rainfall given by the Oracle and updated the Inusrance Contract state
     */ 
    function checkContractCallBack(bytes32 _requestId, uint256 _rainfall) public payable recordChainlinkFulfillment(_requestId) onContractActive() callFrequencyOncePerDay()  {
        //set current temperature to value returned from Oracle, and store date this was retrieved (to avoid spam and gaming the contract)
        currentRainfall = _rainfall;
        currentRainfallDateChecked = now;
        requestCount +=1;
        emit dataReceived(_rainfall);
        
        //check if payout conditions have been met, if so call payoutcontract, which should also end/kill contract at the end
        if (currentRainfall == 0 ) { //temp threshold has been  met, add a day of over threshold
            daysWithoutRain += 1;
        } else {
            //there was rain today, so reset daysWithoutRain parameter 
            daysWithoutRain = 0;
            emit ranfallThresholdReset(currentRainfall);
        }
        
        if (daysWithoutRain >= DROUGHT_DAYS_THRESDHOLD) {  // day threshold has been met
            //need to pay client out insurance amount
            payOutContract();
        }
    }
    
    
    /**
     * @dev Insurance conditions have been met, do payout of total cover amount to client
     */ 
    function payOutContract() private onContractActive()  {
        
        //Transfer agreed amount to client
        client.transfer(payoutValue);
        
        //Transfer any remaining funds (premium) back to Insurer
        insurer.transfer(address(this).balance);
        LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
        require(link.transfer(insurer, link.balanceOf(address(this))), "Unable to transfer");
        
        emit contractPaidOut(now, payoutValue, currentRainfall);
        
        //now that amount has been transferred, can end the contract 
        //mark contract as ended, so no future calls can be done
        contractActive = false;
        contractPaid = true;
    
    }  
    
    /**
     * @dev Insurance conditions have not been met, and contract expired, end contract and return funds
     */ 
    function endContract() private onContractEnded()   {
        //Insurer needs to have performed at least 1 weather call per day to be eligible to retrieve funds back.
        //We will allow for 1 missed weather call to account for unexpected issues on a given day.
        if (requestCount >= (duration.div(DAY_IN_SECONDS) - 1)) {
            //return funds back to insurance provider then end/kill the contract
            insurer.transfer(address(this).balance);
        } else { //insurer hasn't done the minimum number of data requests, client is eligible to receive his premium back
            client.transfer(premium);
            insurer.transfer(address(this).balance);
        }
        
        //transfer any remaining LINK tokens back to the insurer
        LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
        require(link.transfer(insurer, link.balanceOf(address(this))), "Unable to transfer remaining LINK tokens");
        
        //mark contract as ended, so no future state changes can occur on the contract
        contractActive = false;
        emit contractEnded(now, address(this).balance);
    }
    
    
    /**
     * @dev Get the balance of the contract
     */ 
    function getContractBalance() external view returns (uint) {
        return address(this).balance;
    } 
    
    /**
     * @dev Get the Crop Location
     */ 
    function getLocation() external view returns (string) {
        return cropLocation;
    } 
    
    
    /**
     * @dev Get the Total Cover
     */ 
    function getPayoutValue() external view returns (uint) {
        return payoutValue;
    } 
    
    
    /**
     * @dev Get the Premium paid
     */ 
    function getPremium() external view returns (uint) {
        return premium;
    } 
    
    /**
     * @dev Get the status of the contract
     */ 
    function getContractStatus() external view returns (bool) {
        return contractActive;
    }
    
    /**
     * @dev Get whether the contract has been paid out or not
     */ 
    function getContractPaid() external view returns (bool) {
        return contractPaid;
    }
    
    
    /**
     * @dev Get the current recorded rainfall for the contract
     */ 
    function getCurrentRainfall() external view returns (uint) {
        return currentRainfall;
    }
    
    /**
     * @dev Get the recorded number of days without rain
     */ 
    function getDaysWithoutRain() external view returns (uint) {
        return daysWithoutRain;
    }
    
    /**
     * @dev Get the count of requests that has occured for the Insurance Contract
     */ 
    function getRequestCount() external view returns (uint) {
        return requestCount;
    }
    
    /**
     * @dev Get the last time that the rainfall was checked for the contract
     */ 
    function getCurrentRainfallDateChecked() external view returns (uint) {
        return currentRainfallDateChecked;
    }
    
    /**
     * @dev Get the contract duration
     */ 
    function getDuration() external view returns (uint) {
        return duration;
    }
    
    /**
     * @dev Get the contract start date
     */ 
    function getContractStartDate() external view returns (uint) {
        return startDate;
    }
    
    /**
     * @dev Get the current date/time according to the blockchain
     */ 
    function getNow() external view returns (uint) {
        return now;
    }
    
    /**
     * @dev Get address of the chainlink token
     */ 
    function getChainlinkToken() public view returns (address) {
        return chainlinkTokenAddress();
    }
    
    /**
     * @dev Helper function for converting a string to a bytes32 object
     */ 
    function stringToBytes32(string memory source) private pure returns (bytes32 result) {
        bytes memory tempEmptyStringTest = bytes(source);
        if (tempEmptyStringTest.length == 0) {
         return 0x0;
        }

        assembly { // solhint-disable-line no-inline-assembly
        result := mload(add(source, 32))
        }
    }
    
    
    /**
     * @dev Helper function for converting uint to a string
     */ 
    function uint2str(uint _i) internal pure returns (string memory _uintAsString) {
        if (_i == 0) {
            return "0";
        }
        uint j = _i;
        uint len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint k = len - 1;
        while (_i != 0) {
            bstr[k--] = byte(uint8(48 + _i % 10));
            _i /= 10;
        }
        return string(bstr);
    }
    
    /**
     * @dev Fallback function so contrat can receive ether when required
     */ 
    function() external payable {  }

    
}



