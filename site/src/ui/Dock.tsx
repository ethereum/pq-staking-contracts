// Action dock: one tile per operation; only the open tile shows its form.
import { AnimatePresence, motion } from 'motion/react'
import { type CSSProperties, type ReactNode, useEffect, useState } from 'react'
import type { Role } from '../sim/consensus'
import type { Actor, Simulation, TxKind } from '../sim/simulation'
import type { StakeView } from './view'

export const KIND_COLOR: Record<TxKind, string> = {
  stake: 'var(--k-stake)',
  topup: 'var(--k-topup)',
  register: 'var(--k-register)',
  withdraw: 'var(--k-withdraw)',
  consolidate: 'var(--k-consolidate)',
}

interface DockProps {
  sim: Simulation
  actor: Actor
  stakes: StakeView[]
  selectedStake: bigint | undefined
  send: (action: () => Promise<unknown>) => void
}

const TILES: { kind: TxKind; index: string; title: string; caption: string }[] = [
  { kind: 'stake', index: '01', title: 'Stake', caption: 'ETH + withdrawal credentials + key commitment → stake ID' },
  { kind: 'topup', index: '02', title: 'Top up', caption: 'topup(stake_id)' },
  { kind: 'register', index: '03', title: 'Register', caption: 'PQ key (32 B) + leanXMSS proof of possession (2404 B), verified on the EL' },
  { kind: 'consolidate', index: '04', title: 'Consolidate', caption: 'source and target by stake ID' },
  { kind: 'withdraw', index: '05', title: 'Exit / withdraw', caption: 'amount 0 = everything' },
]

export function Dock(props: DockProps) {
  const [open, setOpen] = useState<TxKind>('stake')
  return (
    <aside className="dock">
      {TILES.map((tile) => (
        <motion.div
          key={tile.kind}
          layout
          className={`tile ${open === tile.kind ? 'open' : ''}`}
          style={{ '--kind': KIND_COLOR[tile.kind] } as CSSProperties}
        >
          <button className="tile-head" onClick={() => setOpen(tile.kind)}>
            <span className="tile-index">{tile.index}</span>
            <span className="tile-title">{tile.title}</span>
          </button>
          <AnimatePresence initial={false}>
            {open === tile.kind && (
              <motion.div
                className="tile-body"
                initial={{ height: 0, opacity: 0 }}
                animate={{ height: 'auto', opacity: 1 }}
                exit={{ height: 0, opacity: 0 }}
                transition={{ duration: 0.25, ease: 'easeOut' }}
              >
                <p className="tile-caption">{tile.caption}</p>
                <Form kind={tile.kind} {...props} />
              </motion.div>
            )}
          </AnimatePresence>
        </motion.div>
      ))}
    </aside>
  )
}

function Field(props: { label: string; children: ReactNode }) {
  return (
    <label className="field">
      <span>{props.label}</span>
      {props.children}
    </label>
  )
}

function StakePicker(props: {
  stakes: StakeView[]
  value: string
  onChange: (v: string) => void
  filter?: (s: StakeView) => boolean
}) {
  const options = props.stakes.filter(props.filter ?? (() => true))
  return (
    <select value={props.value} onChange={(e) => props.onChange(e.target.value)}>
      <option value="">—</option>
      {options.map((s) => (
        <option key={s.id.toString()} value={s.id.toString()}>
          #{s.id.toString()} · {s.owner} · {s.status}
        </option>
      ))}
    </select>
  )
}

function Form({ kind, sim, actor, stakes, selectedStake, send }: DockProps & { kind: TxKind }) {
  const [amount, setAmount] = useState(kind === 'stake' ? '32' : kind === 'withdraw' ? '0' : '1')
  const [stakeId, setStakeId] = useState('')
  const [target, setTarget] = useState('')
  const [role, setRole] = useState<Role>('validator')
  const [tamper, setTamper] = useState<'none' | 'wrongPqKey' | 'badPqSignature'>('none')

  // Clicking a stake card selects it for the open form.
  useEffect(() => {
    if (selectedStake !== undefined) setStakeId(selectedStake.toString())
  }, [selectedStake])

  const id = stakeId === '' ? undefined : BigInt(stakeId)

  if (kind === 'stake') {
    return (
      <div className="form">
        <Field label="amount (ETH)">
          <input value={amount} onChange={(e) => setAmount(e.target.value)} inputMode="decimal" />
        </Field>
        <button className="send" onClick={() => send(() => sim.stake(actor, amount))}>
          Send
        </button>
      </div>
    )
  }

  if (kind === 'topup') {
    return (
      <div className="form">
        <Field label="stake">
          <StakePicker stakes={stakes} value={stakeId} onChange={setStakeId} />
        </Field>
        <Field label="amount (ETH)">
          <input value={amount} onChange={(e) => setAmount(e.target.value)} inputMode="decimal" />
        </Field>
        <button className="send" disabled={id === undefined} onClick={() => send(() => sim.topUp(actor, id!, amount))}>
          Send
        </button>
      </div>
    )
  }

  if (kind === 'register') {
    return (
      <div className="form">
        <Field label="your stake">
          <StakePicker
            stakes={stakes}
            value={stakeId}
            onChange={setStakeId}
            filter={(s) => s.hasKeys && s.ownerAddress.toLowerCase() === actor.address.toLowerCase()}
          />
        </Field>
        <div className="segmented">
          {(['validator', 'builder'] as const).map((r) => (
            <button key={r} className={role === r ? 'on' : ''} onClick={() => setRole(r)}>
              {r}
            </button>
          ))}
        </div>
        <Field label="signatures">
          <select value={tamper} onChange={(e) => setTamper(e.target.value as typeof tamper)}>
            <option value="none">valid proof</option>
            <option value="wrongPqKey">valid proof, different key (fails on the CL)</option>
            <option value="badPqSignature">corrupt proof (reverts on the EL)</option>
          </select>
        </Field>
        <button
          className="send"
          disabled={id === undefined || !sim.keys.has(id)}
          onClick={() =>
            send(() =>
              sim.register(actor, role, id!, {
                wrongPqKey: tamper === 'wrongPqKey',
                badPqSignature: tamper === 'badPqSignature',
              }),
            )
          }
        >
          Send
        </button>
      </div>
    )
  }

  if (kind === 'consolidate') {
    return (
      <div className="form">
        <Field label="source">
          <StakePicker stakes={stakes} value={stakeId} onChange={setStakeId} />
        </Field>
        <Field label="target">
          <StakePicker stakes={stakes} value={target} onChange={setTarget} />
        </Field>
        <button
          className="send"
          disabled={id === undefined || target === ''}
          onClick={() => send(() => sim.consolidate(actor, id!, BigInt(target)))}
        >
          Send
        </button>
      </div>
    )
  }

  const amountGwei = BigInt(Math.round(Number(amount || '0') * 1e9))
  return (
    <div className="form">
      <Field label="stake">
        <StakePicker stakes={stakes} value={stakeId} onChange={setStakeId} />
      </Field>
      <Field label="amount (ETH, 0 = all)">
        <input value={amount} onChange={(e) => setAmount(e.target.value)} inputMode="decimal" />
      </Field>
      <button className="send" disabled={id === undefined} onClick={() => send(() => sim.withdraw(actor, id!, amountGwei))}>
        Send
      </button>
    </div>
  )
}
