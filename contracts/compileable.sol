//SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import "@openzeppelin/contracts/utils/Strings.sol";
import '@chainlink/contracts/src/v0.8/ChainlinkClient.sol';
import '@chainlink/contracts/src/v0.8/ConfirmedOwner.sol';
 
//The FairData Mananger (FDM) transparently records requests of data seekers on personal data of data owners.
//While doing so, it enables data owners to be paid for their personal data and 
//data seekers benefit from an immutable and permanent FairData certificate, verifying their ethically correct obtainment of personal data. 
contract FairDataManager is ChainlinkClient, ConfirmedOwner {

    event PersonalData (string name);
    event AdulthoodProof(bool adult);
    event PaymentAccepted(bool accepted);
    event RequestAccepted(uint requestId, address from, address to);
    event RequestDenied(uint requestId, address from, address to);
    event Locked(address locker, uint lockedAmount);

    struct Request {
        address from;
        address to;
        uint amount;
        bool accepted;
    }

    uint public requestCount=0;
    mapping(uint => Request) public requests;
    mapping(address => uint[]) private personalRequests;
    mapping(uint => bool) public requestProcessed;

    //for chainlink's any api serivce
    using Chainlink for Chainlink.Request;
    uint256 private fee;

    constructor() payable ConfirmedOwner(msg.sender) {
        setChainlinkToken(0x326C977E6efc84E512bB9C30f76E30c160eD06FB);
        setChainlinkOracle(0xCC79157eb46F5624204f47AB42b3906cAA40eaB7); //chainlink's testnet oracle on goerli 
        fee = (1 * LINK_DIVISIBILITY) / 10; // 0,1 * 10**18 (Varies by network and job)
    }

    receive() external payable {
        emit Locked(msg.sender, msg.value);
    }

    //public function to check if a data owner is an adult without sharing the exact birthday (for free)
    //test function with address: 0xd04a70063a8383F1142737fFb8C53527907C88eC (minor) and 0xdfaB538a677F7c84B43d379f7bFE90B85Cc18539 (adult)
    function zkProofAdulthood (string memory _address) public returns (bytes32 requestId) {
        Chainlink.Request memory req = buildChainlinkRequest("ca98366cc7314957b8c012c72f05aeeb", address(this), this.fulfillZkProofAdulthood.selector);
        req.add('get', string.concat('https://fair-data.herokuapp.com/app/user/', _address));
        req.add('path', 'birthday');

        // Sends the request
        return sendChainlinkRequest(req, fee);
    }

    //note: birthday is uint as it is in unix epoch format
    function fulfillZkProofAdulthood (bytes32 _requestId, uint _birthday) public recordChainlinkFulfillment(_requestId) {
        if(_birthday + 18 * 365 days < block.timestamp){
            emit AdulthoodProof(true);
        }else{
            emit AdulthoodProof(false);
        }
    }

    function makeRequest(address _to) public payable{

        //data seeker locks money into 
        require(msg.value > 0, "No personal data is for free!");
        (bool success, ) = address(this).call{value: msg.value}(""); //TODO improve: allow smart contract to send _amount either via approval function
        require(success, "No money, no data!");

        //transparently record request
        requests[requestCount] = Request(msg.sender, _to, msg.value * 999 / 1000, false); //smart contract keeps 0.1% of amount data seekers offers for data
        personalRequests[_to].push(requestCount);
        requestCount++;
    }

    //getter for data owners to overview the requests on their data
    function getPersonalRequests() public view returns (uint[] memory) {
        return personalRequests[msg.sender];
    }

    function approveRequest(uint _requestId) public {
        require(requests[_requestId].to == msg.sender, "Not eligable to approve request");
        require(requestProcessed[_requestId] == false, "Request was already processed");

        //pay data owner for sharing personal data
        (bool success, ) = requests[_requestId].from.call{value: requests[_requestId].amount}(""); //payment by smart contract
        require(success, "Payment of data owner unsuccessful");

        //transparently record that sharing of personal data is accepted (= FairData certificate for data seeker)
        requests[_requestId].accepted = true;
        emit RequestAccepted(_requestId, requests[_requestId].from, requests[_requestId].to);

        //mark request as processed
        requestProcessed[_requestId] = true;

        //next: the web 2.0 app calls the forwardPersonalData function --> TODO make it an internal procedure
    }   

    //function called by app layer to forward personal data to data seeker
    //test function with address: 0xd04a70063a8383F1142737fFb8C53527907C88eC
    //TODO get rid of _address input (only existing due to difficulty of casting address to string) --> if address castable to string than this can be an internal function
    function forwardPersonalData(uint _requestId, string memory _address) public returns (bytes32 requestId) {
        require(requests[_requestId].accepted, "Forwarding of personal data not authorized");
        
        //get personal data (i.e. name) if owner of said personal data signs transaction
        Chainlink.Request memory req = buildChainlinkRequest("7d80a6386ef543a3abb52817f6707e3b", address(this), this.fulfillRequestPersonalData.selector);
        req.add('get', string.concat('https://fair-data.herokuapp.com/app/user/', _address));
        req.add('path', 'name');

        //Sends the request
        return sendChainlinkRequest(req, fee);
    }

    function fulfillRequestPersonalData (bytes32 _requestId, string memory _name) public recordChainlinkFulfillment(_requestId) {
        emit PersonalData(_name); //TODO how to make sure that only the paying data seekers sees personal data --> solution: return the personal data instead of logging it on the public events log
    }

    function declineRequest(uint _requestId) public {
        require(requests[_requestId].to == msg.sender, "Not eligable to decline request");
        
        //TODO eventually send locked ether back to receiver
        emit RequestDenied(_requestId, requests[_requestId].from, requests[_requestId].to);
        
        //mark request as processed
        requestProcessed[_requestId] = true;
        
    }

    /**
     * functions for withdrawing crypto locked in smart contract
     */
    function withdrawLink() public onlyOwner {
        LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
        require(link.transfer(msg.sender, link.balanceOf(address(this))), 'Unable to transfer');
    }

    function withdrawEth(uint _percentage) public onlyOwner {
        (bool success, ) = msg.sender.call{value : address(this).balance * _percentage / 100}("");
        require(success, 'Unable to transfer');
    }
}