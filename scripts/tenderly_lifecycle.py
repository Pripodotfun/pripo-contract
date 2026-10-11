#!/usr/bin/env python3
"""Journaled, separately deployed lifecycle-v1 fork demo. Never upgrade the existing markets."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
import subprocess
import time

from deploy_tenderly import prepare_source, save, verified_receipts
from deploy_testnet import keccak
from mock_testnet import calldata
from monad_preflight import ROOT, ProbeError, rpc
from run_monad_fork import redact_output
from tenderly_demo import context, words
from tenderly_environment import CHAIN_ID, SENDER
import tenderly_pyth_market as prior

FOLDER = ROOT / 'reports/deployment/tenderly-lifecycle'
SOURCE = FOLDER / 'source'
OLD = ROOT / 'deployments/tenderly-demo.json'


def deploy(env, proof, execute):
    source = prepare_source(FOLDER)
    config = json.loads(OLD.read_text())['manifest']
    save(SOURCE / 'reports/deployment/config.json', config)
    journal = FOLDER / 'deploy.json'
    if journal.exists():
        record = json.loads(journal.read_text())
        if record['status'] == 'verified' and record['environment'] == proof:
            print('Deployment already verified; not resubmitting.')
            return
        raise ProbeError('An incomplete deployment journal exists; reconcile before retrying')
    child = dict(env, DEPLOYER=SENDER, TENDERLY_SINGLE_ACCOUNT_DEMO='true', FOUNDRY_PROFILE='default',
                 DEPLOY_CONFIG='reports/deployment/config.json', DEPLOY_OUTPUT='reports/deployment/manifest.json')
    for key in ('FUNDED_DEPLOYER_PRIVATE_KEY', 'TENDERLY_ACCESS_KEY', 'PYTH_API_KEY'):
        child.pop(key, None)
    command = ['forge', 'script', 'script/TenderlyLifecycle.s.sol:DeployTenderlyLifecycle', '--rpc-url', 'tenderly', '--sender', SENDER, '--slow', '-vv']
    def run(broadcast):
        result = subprocess.run(command + (['--broadcast', '--unlocked'] if broadcast else []), cwd=SOURCE, env=child, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        output = redact_output(result.stdout, env)
        (FOLDER / ('deploy-broadcast.log' if broadcast else 'deploy-plan.log')).write_text(output)
        if result.returncode:
            raise ProbeError('Foundry deployment failed; inspect the redacted lifecycle log before retrying')
        path = SOURCE / f'broadcast/TenderlyLifecycle.s.sol/{CHAIN_ID}'
        if not broadcast:
            path /= 'dry-run'
        plan = json.loads((path / 'run-latest.json').read_text())
        if not 9 <= len(plan['transactions']) <= 20 or any(t['transactionType'] not in ('CREATE','CREATE2') or t['transaction']['from'].lower() != SENDER.lower() for t in plan['transactions']):
            raise ProbeError('Unexpected creation plan or sender')
        manifest=json.loads((SOURCE/'reports/deployment/manifest.json').read_text())
        resolver=json.loads((SOURCE/'reports/deployment/resolver.json').read_text())
        pairs=list(zip(manifest['contracts'],manifest['runtimeCodeHashes']))+[(resolver['resolver'],resolver['runtimeCodeHash'])]
        created={t['contractAddress'].lower() for t in plan['transactions']}
        if not created.issubset({a.lower() for a,_ in pairs}):
            raise ProbeError('Unrecognized creation target')
        reused=[]
        for address,expected in pairs:
            if address.lower() not in created:
                if keccak(rpc(env['TENDERLY_RPC'],'eth_getCode',[address,'latest'])).lower()!=expected.lower():
                    raise ProbeError('Reused library runtime mismatch')
                reused.append(address)
        plan['verifiedReusedLibraries']=reused
        save(FOLDER / ('deploy-broadcast.json' if broadcast else 'deploy-plan.json'), plan)
        return plan
    planned = run(False)
    if not execute:
        print('Separate lifecycle deployment simulated; unchanged deterministic libraries verified.')
        return
    if context()[2] != proof:
        raise ProbeError('Environment changed during simulation')
    save(journal, dict(status='submitting', source=source, environment=proof))
    actual = run(True)
    def intended(item):
        tx = item['transaction']
        return (tx['from'].lower(), tx.get('to'), tx.get('input') or tx.get('data'), tx.get('value'), tx.get('nonce'))
    if [intended(t) for t in planned['transactions']] != [intended(t) for t in actual['transactions']]:
        raise ProbeError('Broadcast differs from the simulated plan')
    costs = verified_receipts(env['TENDERLY_RPC'], actual['transactions'])
    manifest = json.loads((SOURCE / 'reports/deployment/manifest.json').read_text())
    resolver = json.loads((SOURCE / 'reports/deployment/resolver.json').read_text())
    pairs = list(zip(manifest['contracts'], manifest['runtimeCodeHashes'])) + [(resolver['resolver'], resolver['runtimeCodeHash'])]
    def check(pair):
        address, expected = pair
        if keccak(rpc(env['TENDERLY_RPC'], 'eth_getCode', [address, 'latest'])).lower() != expected.lower():
            raise ProbeError('Deployed runtime does not match compiled manifest')
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(check, pairs))
    if {c['createdAddress'].lower() for c in costs} | {a.lower() for a in actual['verifiedReusedLibraries']} != {a.lower() for a, _ in pairs}:
        raise ProbeError('Creation receipts do not cover all twenty contracts')
    save(FOLDER/'manifest.json',manifest)
    save(FOLDER/'resolver.json',resolver)
    save(journal,dict(status='verified',source=source,environment=proof,transactions=costs,verifiedAt=datetime.now(timezone.utc).isoformat()))
    print(json.dumps({'deployed':len(costs),'reusedLibraries':len(actual['verifiedReusedLibraries']),'factory':manifest['factory'],'vault':manifest['vault'],'resolver':resolver['resolver']}))


class Lifecycle(prior.Demo):
    def __init__(self):
        self.env,self.url,self.proof=context()
        FOLDER.mkdir(parents=True,exist_ok=True)
        self.old=json.loads(OLD.read_text())
        self.m=json.loads((FOLDER/'manifest.json').read_text())
        self.resolver=json.loads((FOLDER/'resolver.json').read_text())
        self.record={'environment':self.proof,'demoOnly':True,'manifest':self.m}
        prior.FOLDER=FOLDER
        self.check_bindings()

    def empty_book(self):
        # Check both factories immediately before every clock adjustment.
        for f in (self.old['manifest']['factory'],self.m['factory']):
            for i in range(self.w(f,'marketCount()')[0]):
                a='0x'+format(self.w(f,'markets(uint256)',i)[0],'040x')
                if self.w(a,'positionCount()')!=[0]:
                    raise ProbeError('Time travel refused: an existing market has open positions')

    def clock(self,name,stamp):
        self.empty_book()
        return super().clock(name,stamp)

    def configure(self):
        m=self.m;f=m['factory'];v=m['vault'];a=m['pythAdapter']
        calls=[('backstop',v,'setBackstopController(address)',[m['backstop']]),('registrar',v,'setRegistrar(address,bool)',[f,'true']),
               ('bind-resolver',f,'setResolver(address)',[self.resolver['resolver']]),('reserve-approve',m['usdc'],'approve(address,uint256)',[v,10_000*10**6]),
               ('reserve',v,'fundProtocolReserve(uint256)',[10_000*10**6]),('schedule',f,'scheduleAdapter(address)',[a])]
        for name,target,sig,args in calls:
            self.transaction(name,target,calldata(sig,*args))
        if self.w(f,'allowedAdapters(address)',a)!=[1]:
            ready=self.w(f,'adapterReadyAt(address)',a)[0]
            self.clock('governance-delay',ready)
            try:
                self.transaction('activate',f,calldata('activateAdapter(address)',a))
            finally:
                self.clock('restore-wall-clock',int(time.time()))
        self.transaction('feed-approve',m['usdc'],calldata('approve(address,uint256)',f,500*10**6))
        self.transaction('feed-list',f,calldata('listFeed(address,bytes32)',a,prior.FEED))
        self.transaction('feed-publish',f,calldata('publishFeed(address,bytes32,string,string)',a,prior.FEED,'BTC:USD','Bitcoin / US Dollar'))
        print('Lifecycle custody, resolver, reserve and curated BTC feed configured.')

    def markets(self):
        m=self.m;f=m['factory'];seed=1000*10**6
        depth=self.w(f,'creationEconomics(uint256)',seed)[2]
        self.transaction('markets-approve',m['usdc'],calldata('approve(address,uint256)',f,2*seed))
        p=f"(PRIPO:DEMO,{m['nullAdapter']},0x{'00'*32},{100*10**18},{depth},{seed})"
        self.transaction('create-demo',f,calldata('createMarketWithMetadata((string,address,bytes32,uint256,uint256,uint256),string,bytes)',p,'Pripo Demo','0x'))
        if not (FOLDER/'create-btc.json').exists():
            payload,update=prior.signed_price(self.env)
            fee=self.w(m['pythAdapter'],'updateFee(bytes)',update)[0]
            if fee>10**15:
                raise ProbeError('Unexpected Pyth fee')
            stamp=int(payload['parsed'][0]['price']['publish_time'])
            save(FOLDER/'signed-update.json',{'response':payload,'feeWei':fee})
            self.clock('btc-price',stamp)
            p=f"(BTC:USD,{m['pythAdapter']},{prior.FEED},1,{depth},{seed})"
            data=calldata('createMarketWithMetadata((string,address,bytes32,uint256,uint256,uint256),string,bytes)',p,'Bitcoin / US Dollar',update)
            self.transaction('create-btc',f,data,fee,simulate=False)
        markets=[]
        if self.w(f,'marketCount()')!=[2]:
            raise ProbeError('Expected two lifecycle markets')
        for i in range(2):
            a='0x'+format(self.w(f,'markets(uint256)',i)[0],'040x')
            if self.w(a,'lifecycleVersion()')!=[1] or self.w(a,'operatorLimitsVersion()')!=[1] or self.w(a,'resolver()')!=[int(self.resolver['resolver'],16)]:
                raise ProbeError('Lifecycle market binding mismatch')
            if self.w(m['vault'],'insuranceCap(address)',a)!=[10_000*10**18]:
                raise ProbeError('Insurance cap mismatch')
            markets.append({'address':a,'symbol':['PRIPO:DEMO','BTC:USD'][i],'company':['Pripo Demo','Bitcoin / US Dollar'][i],'external':bool(i)})
        d=json.loads((FOLDER/'deploy.json').read_text())
        result={'network':'tenderly-lifecycle','demoOnly':True,'productionReady':False,'environment':self.proof,'source':d['source'],'manifest':m,'resolver':self.resolver,'markets':markets,'startBlock':min(t['block'] for t in d['transactions']),
                'transactions':{p.stem:json.loads(p.read_text())['receipt'] for p in FOLDER.glob('*.json') if 'receipt' in json.loads(p.read_text())},
                'governance':'Single demo governor; five distinct impersonated council addresses. No independent production council.',
                'previousDeployment':'tenderly-demo.json'}
        save(ROOT/'deployments/tenderly-lifecycle.json',result)
        print(json.dumps({'verified':True,'markets':markets,'startBlock':result['startBlock']}))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage',choices=['inspect','deploy','configure','markets'])
    parser.add_argument('--execute',action='store_true')
    args=parser.parse_args()
    env,url,proof=context()
    if args.stage=='inspect':
        old=json.loads(OLD.read_text())['manifest'];rows=[]
        for i in range(words(url,old['factory'],'marketCount()')[0]):
            a='0x'+format(words(url,old['factory'],'markets(uint256)',i)[0],'040x')
            rows.append({'address':a,'positions':words(url,a,'positionCount()')[0]})
        print(json.dumps({'oldMarkets':rows,'chainId':int(rpc(url,'eth_chainId',[]),16)}))
    elif args.stage=='deploy':
        deploy(env,proof,args.execute)
    elif not args.execute:
        raise ProbeError('Use --execute for a journaled fork-only stage')
    else:
        getattr(Lifecycle(),args.stage)()

if __name__=='__main__':
    try:
        main()
    except ProbeError as exc:
        raise SystemExit(str(exc)) from None
