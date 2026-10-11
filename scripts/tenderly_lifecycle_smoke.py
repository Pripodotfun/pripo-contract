#!/usr/bin/env python3
"""Exercise delegated trading and disputed settlement on a dedicated fork-only market."""
import json
import time
from pathlib import Path
from monad_preflight import ROOT, ProbeError, rpc
from mock_testnet import calldata
from deploy_tenderly import save
from tenderly_lifecycle import Lifecycle, FOLDER
from tenderly_environment import SENDER
import tenderly_pyth_market as prior

OPERATOR='0x000000000000000000000000000000000000b0b1'
DISPUTER='0x000000000000000000000000000000000000b0b2'
WAD=10**18

def main():
    demo=Lifecycle();m=demo.m;f=m['factory'];v=m['vault'];r=demo.resolver['resolver'];token=m['usdc']
    def tx(name,target,sig,*args,sender=SENDER,value=0):
        original=prior.SENDER
        prior.SENDER=sender
        try:
            return demo.transaction('smoke-'+name,target,calldata(sig,*args) if sig else '0x',value)
        finally:
            prior.SENDER=original
    seed=1000*10**6;depth=demo.w(f,'creationEconomics(uint256)',seed)[2]
    tx('seed-approve',token,'approve(address,uint256)',f,seed)
    tx('market',f,'createMarketWithMetadata((string,address,bytes32,uint256,uint256,uint256),string,bytes)',
       f"(PRIPO:CHECK,{m['nullAdapter']},0x{'00'*32},{100*WAD},{depth},{seed})",'Lifecycle verification','0x')
    market='0x'+format(demo.w(f,'marketForSymbol(bytes32)',__import__('deploy_testnet').keccak('PRIPO:CHECK'))[0],'040x')
    declaration=FOLDER/'smoke-declare.json'
    if not declaration.exists():
        head=rpc(demo.url,'eth_getBlockByNumber',['latest',False]);expected=max(int(head['timestamp'],16),int(time.time()))+60
        tx('declare',r,'declareSettlement(address,uint8,uint64,string)',market,0,expected,'Fork-only lifecycle verification event')
        # Keep a live oracle-compatible clock. This short rehearsal waits for its
        # event instead of leaving a time-travel offset on the shared demo fork.
        while time.time() <= expected:
            print('Waiting for the declared demo event time...', flush=True)
            time.sleep(min(10, max(1, expected - time.time() + 1)))
    tx('deposit-approve',token,'approve(address,uint256)',v,1000*10**6)
    tx('deposit',v,'deposit(uint256)',1000*10**6)
    tx('operator-gas',OPERATOR,'',value=10**18)
    expiry=demo.w(v,'operators(address,address)',SENDER,OPERATOR)[0]
    policyPath=FOLDER/'smoke-policy-input.json'
    if policyPath.exists():
        policy=json.loads(policyPath.read_text())['policy']
    else:
        head=rpc(demo.url,'eth_getBlockByNumber',['latest',False]);expiry=int(head['number'],16)+100000
        policy=f"({expiry},{500*WAD},{5000*WAD},0,0x{'00'*32},true)"
        save(policyPath,{'policy':policy})
    tx('policy',v,'setOperatorWithLimits(address,(uint64,uint128,uint128,uint128,bytes32,bool),(uint128,uint128,uint16),string)',OPERATOR,policy,f'({500*WAD},{50*WAD},1)','lifecycle-check')
    tx('profile',f,'setProfileName(string)','Pripo_Demo')
    tx('operator-open',market,'openFor(address,int256,uint256,bytes)',SENDER,WAD,101*WAD,'0x',sender=OPERATOR)
    tx('operator-close-half',market,'closeFor(address,uint256,uint256,bytes)',SENDER,WAD//2,99*WAD,'0x',sender=OPERATOR)
    tx('revoke',v,'revokeOperator(address)',OPERATOR)
    rejected=False
    try:
        rpc(demo.url,'eth_call',[{'from':OPERATOR,'to':market,'data':calldata('closeFor(address,uint256,uint256,bytes)',SENDER,WAD,99*WAD,'0x')},'latest'])
    except ProbeError:
        rejected=True
    if not rejected:
        raise ProbeError('Revoked operator was not rejected')
    tx('proposal-approve',token,'approve(address,uint256)',r,2500*10**6)
    tx('propose',r,'propose(address,uint256,string)',market,110*WAD,'Fork-only proposed terminal price')
    tx('disputer-gas',DISPUTER,'',value=10**18)
    tx('disputer-fund',token,'transfer(address,uint256)',DISPUTER,2500*10**6)
    tx('dispute-approve',token,'approve(address,uint256)',r,2500*10**6,sender=DISPUTER)
    tx('dispute',r,'disputeWithReason(address,uint256,string)',market,105*WAD,'Fork-only counter-price verification',sender=DISPUTER)
    for i,member in enumerate(demo.resolver['council'][:3]):
        tx('council-gas-'+str(i),member,'',value=10**18)
        tx('vote-'+str(i),r,'councilResolve(address,uint256)',market,105*WAD,sender=member)
    before=demo.w(market,'settlementClaim(address)',SENDER)[0]
    claimPath=FOLDER/'smoke-claim.json'
    if not claimPath.exists() and before<=0:
        raise ProbeError('No terminal claim available')
    tx('claim',market,'claimSettlement()')
    if demo.w(market,'settlementClaim(address)',SENDER)!=[0] or demo.w(market,'positionCount()')!=[0]:
        raise ProbeError('Claim did not clear the settlement balance')
    tx('bond-claim',r,'claimBonds()',sender=DISPUTER)
    if demo.w(r,'credits(address)',DISPUTER)!=[0]:
        raise ProbeError('Bond credit did not clear')
    checks={'operatorOpenAndClose':True,'revokedOperatorRejected':True,'disputeResolvedByThreeVotes':True,'positionClaimCleared':True,'bondClaimCleared':True}
    result={'market':market,'symbol':'PRIPO:CHECK','checks':checks,'environment':demo.proof,'transactions':{p.stem:json.loads(p.read_text())['receipt'] for p in FOLDER.glob('smoke-*.json') if 'receipt' in json.loads(p.read_text())}}
    save(ROOT/'deployments/tenderly-lifecycle-smoke.json',result)
    # Check actual pending EVM time after all positions are cleared.
    from tenderly_clock import restore
    restore(demo, FOLDER, 'smoke-restore-live-clock')
    print(json.dumps({'market':market,'checks':checks}))

if __name__=='__main__':
    try:
        main()
    except ProbeError as exc:
        raise SystemExit(str(exc)) from None
