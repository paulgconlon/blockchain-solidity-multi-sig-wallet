// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.4;

// Description:
// Multi Signature Wallet.
// A contract that accepts payments into an aggregated pool and responds to requests to withdraw by addresses configured at deployment only. See m_approver_addresses.
// Withdrawals are only actioned when a minimum number of withdraw requests (also known as approvals) for a particular (indexed) withdrawal is reached. See m_approver_addresses.
// Each withdrawal request is represented by the ApprovablePayment struct.
// All withdrawal requests tracked by the contract are stored in the m_approvable_payments mapping.
//
// Usage:
// Deposit funds to contract by calling the deposit function. Depositor addresses are not tracked and funds are stored in aggregate.
// Withdraw funds by calling the request_and_approve_payment function with an index representing the unique transaction.
// Each unique call to request_and_approve_payment by an address in m_approver_addresses will increment the number of approvals for the parametised index.
// A withdrawal request is also an approval for that withdrawal.
// Approvals cannot be made when the withdrawal request amount is more than the contract balance.
// Once the approval threshold number is reached, the withdrawal is actioned and the withdrawal request flagged so; meaning that index can not be resent.
// All payment amounts are in units of wei.
//
// Enhancements:
// A function to check the sent / approval state of a given withdrawal request index could be handy. It could return "x of y approvals" and whether the transfer has been made.

contract MultiSigWallet {
    
    // **VARIABLES**
    
    // Only these addresses may approve payments. By design the owner may not be an approver as this allows the contract to be deployed for others to use.
    address[] private m_approver_addresses; 
    
    // Configured when deployed. when this many approvals for a withdrawal request index is reached then transfer funds.
    uint private m_min_approval_count_to_send; 
    
    // The current contract balance in wei.
    uint public m_contract_balance_wei;
    
    // Each withdrawal request contains payment details, transaction state and a mapping of which approver has approved the payment in response to request_and_approve_payment calls
    struct ApprovablePayment { 
        address payable address_destination;
        uint amount;
        mapping(address => bool) approvals;
        bool payment_sent;
        bool payment_initialised;
    }
    
    // **EVENTS**
    
    // Emitted from deposit function when funds added to this contract.
    event depositDone(uint _amount_wei, address indexed _depositedTo);
    
    // Emitted when request_and_approve_payment iterates over the m_approver_addresses array informing of which approver has approved the parametised withdrawal index already.
    event approvalIterationUpdate(uint loopCount, uint approvalCount, address indexed msgSender, address indexed checkingThisApprover, bool approvalFlag);
    
    // Emitted each time an existing approval for withdrawal index is found when request_and_approve_payment iterates over the m_approver_addresses array. See approvalIterationUpdate.
    event approvalFoundFor(address indexed approver);
    
    // Emmitted when request_and_approve_payment finds the approval count for a withdrawal index has met or m_min_approval_count_to_send just prior to enacting the transfer.
    event paymentApproved(uint approvalCount, address indexed sendingTo);
    
    // The payment details for all withdrawal request indexes ever seen by request_and_approve_payment, both sent and unsent.
    // A mapping is more efficient than an array with nested indexing as iteration over the growing array would consume increasing amounts of gas over time.
    mapping(uint => ApprovablePayment) private m_approvable_payments;
    
    // **MODIFIERS**
    
    // Guards request_and_approve_payment from being called by addresses not configured as approver addresses upon contract deployment.
    modifier onlyApprover {
        uint approver_length = m_approver_addresses.length;
        bool approver = false;
        for (uint i=0; i<approver_length; ++i) {
            if (msg.sender == m_approver_addresses[i]) {
                approver = true;
                break;
            }
        }           
        
        require(approver, "Function must be called from an approver address.");
        _; // run the function
    }
    
    // **FUNCTIONS**
    
    // Configure the list of addresses that can requests/approve withdrawals and how many unique approvals are required for each transfer. Count can't exceed list length.
    constructor(address[] memory a_approver_addresses, uint a_min_approval_count_to_send) {
        require(a_min_approval_count_to_send <= a_approver_addresses.length, "Required approval count cannot exceed number of approver addresses.");
	    m_approver_addresses = a_approver_addresses; // decided to make this flexible so that the deployer doesn't need to be an approver. Makes wallet useful to setup for others to use.
	    m_min_approval_count_to_send = a_min_approval_count_to_send;
    }
    
    // Send wei to this contract and have it added to m_contract_balance_wei
    function deposit() public payable returns (uint) {
    	m_contract_balance_wei += msg.value;
    	emit depositDone(msg.value, msg.sender);
    	return m_contract_balance_wei;
    }
    
    // This is where both approvals and transfers are made. 
    // A call to this function will approve the parameterised payment for the calling address and if doing so reaches the required approver count, the transfer is also made.
    // Note that for safety, this fuction implements the Checks Effects Interactions pattern described at https://fravoll.github.io/solidity-patterns/checks_effects_interactions.html
    function request_and_approve_payment(address payable a_destination_address, uint a_amount_wei, uint a_transaction_id) public payable onlyApprover returns (uint) {
        // Check calling address is found in m_approver_addresses (already done by onlyApprover modifier)
        
        // Check we have the balance to attempt this payment before consuming resources to check the approval status.
        require(m_approvable_payments[a_transaction_id].amount <= m_contract_balance_wei, "Insufficient contract funds to attempt payment.");
        
        // If a payment of this id has already been sent then nothing to to. Don't double send.
        require(!m_approvable_payments[a_transaction_id].payment_sent, "The payment for this id has already been sent.");
        
        // If initialised, the requested destination address must match the details we have for this payment id in storage.
        if(m_approvable_payments[a_transaction_id].payment_initialised) {
            require(a_destination_address == m_approvable_payments[a_transaction_id].address_destination, "The specified destination address doesn't match the destination address for this payment ID.");
        }

        // If initialised, the requested transfer amount must match the details we have for this payment id in storage.
        if(m_approvable_payments[a_transaction_id].payment_initialised) {
            require(a_amount_wei == m_approvable_payments[a_transaction_id].amount, "The specified payment amount doesn't match the payment for this payment ID.");
        }
        
        // Step one of two: record our own approval for this transaction id.
        m_approvable_payments[a_transaction_id].address_destination = a_destination_address;
        m_approvable_payments[a_transaction_id].amount = a_amount_wei;
        m_approvable_payments[a_transaction_id].approvals[msg.sender] = true;
        m_approvable_payments[a_transaction_id].payment_initialised = true;
        
        // Step two of two: determine whether our approval has met the threshold required to exercise the transfer - use Checks Effects Interactions pattern here.
        uint approver_length = m_approver_addresses.length;
        uint approval_count = 0;
        for(uint i=0; i<approver_length; ++i) {
            emit approvalIterationUpdate(i, approval_count, msg.sender, m_approver_addresses[i], m_approvable_payments[a_transaction_id].approvals[m_approver_addresses[i]]);
            if( m_approvable_payments[a_transaction_id].approvals[m_approver_addresses[i]]) {
                emit approvalFoundFor(m_approver_addresses[i]);
                if(++approval_count >= m_min_approval_count_to_send) {
                    emit paymentApproved(approval_count, m_approvable_payments[a_transaction_id].address_destination);
                    m_contract_balance_wei -= m_approvable_payments[a_transaction_id].amount;
                    m_approvable_payments[a_transaction_id].payment_sent = true; // confirm approval in the storage struct
                    m_approvable_payments[a_transaction_id].address_destination.transfer(m_approvable_payments[a_transaction_id].amount); // unlike send, this will throw if unsuccessful so we get more information
                    break;
                }
            }
        } 
        return m_contract_balance_wei;
    }
}
