#!/usr/bin/env python3
"""Check or restore the authenticated, empty demo fork's pending EVM clock."""
import argparse
import time

from deploy_tenderly import save
from monad_preflight import ProbeError, rpc

MULTICALL = '0xcA11bde05977b3631167028862bE2a173976CA11'


def pending_time(demo):
    # Tenderly's pending block header can report wall time while eth_call executes
    # with a retained time-travel offset. Read block.timestamp inside the EVM.
    return demo.w(MULTICALL, 'getCurrentBlockTimestamp()', block='pending')[0]


def restore(demo, folder, name='restore-live-clock'):
    demo.empty_book()
    before = rpc(demo.url, 'eth_getBlockByNumber', ['latest', False])
    pending = pending_time(demo)
    stamp = int(time.time())
    if abs(pending - stamp) <= 1:
        time.sleep(2)
        advanced = pending_time(demo)
        wall = int(time.time())
        if advanced > pending and abs(advanced - wall) <= 2:
            return {'pendingEvmTimestamp': advanced, 'wallClockTimestamp': wall, 'clockAdvances': True, 'mutationRequired': False}
        raise ProbeError('Pending EVM clock is frozen; reconcile the virtual environment before retrying')
    if int(before['timestamp'], 16) > stamp:
        raise ProbeError('Wait until wall time catches up with the latest mined block')
    if pending > stamp:
        raise ProbeError('Pending EVM clock is ahead; refusing an unreviewed backward adjustment')
    path = folder / (name + '-' + str(time.time_ns()) + '.json')
    record = dict(environment=demo.proof, beforeBlock=int(before['number'], 16),
                  beforeTimestamp=int(before['timestamp'], 16), pendingEvmTimestamp=pending,
                  requestedTimestamp=stamp, status='submitting')
    save(path, record)
    # Correct the EVM offset by the measured delta. setNextBlockTimestamp on this
    # fork changes the header without reliably clearing a pre-existing offset.
    demo.admin('evm_increaseTime', [hex(stamp - pending)])
    actual = pending_time(demo)
    time.sleep(2)
    advanced = pending_time(demo)
    wall = int(time.time())
    after = rpc(demo.url, 'eth_getBlockByNumber', ['latest', False])
    save(path, dict(record, status='checking', pendingEvmTimestampAfter=advanced,
                    wallClockTimestampAfter=wall, blockAfter=int(after['number'], 16), transactionCount=len(after['transactions'])))
    # Tenderly records its cheatcode as a zero-value administrative transaction.
    transactions = [rpc(demo.url, 'eth_getTransactionByHash', [h]) for h in after['transactions']]
    expected_data = '0x3c9a2a1a' + format(stamp - pending, '064x')
    admin_only = len(transactions) == 1 and transactions[0]['input'] == expected_data and int(transactions[0]['value'], 16) == 0
    if (int(after['number'], 16) != int(before['number'], 16) + 1
            or not admin_only or abs(advanced - wall) > 2 or advanced <= actual):
        raise ProbeError('Pending EVM clock verification failed; inspect the clock journal')
    save(path, dict(record, status='verified', pendingEvmTimestampAfter=advanced,
                    wallClockTimestampAfter=wall, administrativeBlock=int(after['number'], 16), clockAdvances=True))
    return {'pendingEvmTimestamp': advanced, 'wallClockTimestamp': wall, 'administrativeBlock': int(after['number'], 16), 'clockAdvances': True}


if __name__ == '__main__':
    import json
    from tenderly_lifecycle import Lifecycle, FOLDER
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    try:
        demo = Lifecycle()
        if args.execute:
            print(json.dumps(restore(demo, FOLDER)))
        else:
            print(json.dumps({'pendingEvmTimestamp': pending_time(demo), 'wallClockTimestamp': int(time.time())}))
    except ProbeError as exc:
        raise SystemExit(str(exc)) from None
