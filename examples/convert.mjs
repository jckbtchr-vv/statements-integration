// Integration sequence for viem. Call only after verifying the deployed contracts.
// `walletClient.account` must itself own the Statement. For a contract owner,
// implement the same sequence inside that contract; an EOA cannot act as it.
import {parseAbi} from 'viem';
export async function convert({publicClient, walletClient, statements, conversion, statementId}) {
  const statementABI = parseAbi(['function approve(address,uint256)']);
  const conversionABI = parseAbi(['function quote(uint256) view returns(uint256)', 'function withdraw(uint256,uint256) returns(uint256)']);
  const expectedAmount = await publicClient.readContract({address:conversion,abi:conversionABI,functionName:'quote',args:[statementId]});
  const approval = await walletClient.writeContract({address:statements,abi:statementABI,functionName:'approve',args:[conversion,statementId]});
  const receipt = await publicClient.waitForTransactionReceipt({hash:approval});
  if(receipt.status !== 'success') throw Error('Approval failed');
  const {request} = await publicClient.simulateContract({account:walletClient.account,address:conversion,abi:conversionABI,functionName:'withdraw',args:[statementId,expectedAmount]});
  return walletClient.writeContract(request);
}
