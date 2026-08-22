Orchestrate the #163 Ruby-backend issue tree in cpb/duckling.

You are the orchestrator. You do not write backend code yourself — you compute
what is ready, dispatch it, advance what is in flight, and open the next gate.

## Each tick, in this order

1. ADVANCE IN-FLIGHT WORK before starting anything new.
   For every open PR whose head branch is for a `ruby-backend`-labelled issue:
   - CI green + not draft  -> /cpb:finish-pr
   - CI red                -> /cpb:heal-ci (it self-escalates after 5 attempts;
                              when it escalates, stop touching that PR and
                              report it — do not retry by hand)
   - draft                 -> HANDS OFF. Do not push it toward merge, do not
                              mark it ready, do not comment. Drafts are the
                              operator's. Report it and move on.
   - CI still running      -> leave it; that is what the next tick is for.

2. COMPUTE THE READY SET from the gates below. A gate is open when
   `gh issue list -R cpb/duckling --label <L> --state open` returns empty.

   ROOT GATE:  PR #255 must be MERGED (it closes #157). It carries the corpus
   that is this tree's entire spec. Until it merges, the ready set is exactly
   {#255} — drive it with /cpb:finish-pr or /cpb:heal-ci, nothing else.

   Then, in order, each gated on the previous being closed:
     #256                  -> alone, serial. Splits the local corpus fixture
                              into a globbed directory. 42 audit agents cannot
                              run until it lands; they would all append to one
                              JSON file.
     CORPUS STAGE          -> once #256 is merged, ALL of these in parallel:
       label:corpus  (3)      #257 branches, #258 dead rules, #259 with_latent
       label:corpus-audit     43 issues: #209 parent + 42 slice audits
       #164 (phase-0 spine)   the spine does not depend on corpus CONTENT,
                              only on the fixture FORMAT, so it runs alongside
       #165 (ranking)         once #164 is merged
     #166 (phase-1)        -> once label:corpus AND label:corpus-audit are both
                              empty AND #164 is merged. #166 buckets whatever
                              corpus exists when it runs, and its output is
                              every Phase 2 slice's spec — a case added after
                              it runs reaches nobody.
     label:wave-a  (30)    -> once #164 AND #166 are merged
     label:wave-b  (9)     -> once label:wave-a is empty
     label:wave-c  (3)     -> once label:wave-b is empty
     #252 -> #253 -> #254  -> strictly serial. #252 is the residual
                              differential; there is no second audit swarm.

   Never open a gate early. Wave A agents are forbidden from reading the Rust;
   Wave C's `Composed` and `Interval` slices own 61 of the 221 rules and depend
   on Wave A/B resolvers existing.

   The corpus stage is the widest point in the whole tree — 46 issues runnable
   at once. It is also the cheapest, because none of it needs the Ruby backend
   to exist. Do not let it trickle.

3. TOP UP to at most 4 concurrent in-flight issues (there are already ~22
   worktrees on this machine; a 46-way fan-out is 46 worktrees and tmux
   sessions, which is not what "parallel" means here). Pick from the ready
   set, heaviest first — the rule count is in each issue's title, and each
   corpus-audit issue lists how many gaps were pre-identified for its slice.
   For each one you start:
     - issue has the `test-first` label -> /cpb:hill-first
     - otherwise                        -> /cpb:start-pr
   After `bin/worktree` sets up a branch, VERIFY it is based on the right
   commit before any work happens — `bin/worktree prepare` branches off the
   main worktree's current HEAD, which is often a stray branch, not `main`.
   Reset it if wrong.

4. REPORT one short status: gate you are on, what is in flight, what merged
   this tick, what is blocked and on what.

## Skip rules — treat as hard, not advisory

- `backlog`-labelled issues: never pick up. Their bodies say so themselves.
- Draft PRs: never hasten toward closing or merging.
- A tmux session parked at a blocking decision menu: skip it, report it, move
  on. The operator handles those personally.
- PRs #92, #103, #161, #162 are unrelated open work. Do not touch them.
- Push every commit immediately — other agents may be on the same branch.

## If you sub-split a slice

#171 (HourMinute, 26 rules), #201 (Interval, 27), #202 (Composed, 34) and #185
(Holiday) each carry a suggested sub-split, and their agents may act on it. If
a slice is split, the child issues MUST carry the same wave label and be linked
as sub-issues of #163. The gates are label-emptiness checks — an unlabelled
child opens the next wave early and silently. The same applies to any
corpus-audit issue that splits: it must keep `corpus-audit`, or #166 starts
against a corpus that is still growing.

## Stop and ask the operator when

- PR #255 is still unmerged after you have reported it twice — the tree cannot
  start.
- /cpb:heal-ci escalates on any PR.
- A corpus audit finds a NATIVE-backend divergence. The agent opens an
  `upstream-divergence` issue on THIS repo — never against wafer-inc/duckling
  (see "Upstream divergences" in AGENTS.md). You do not triage it, fix it, or
  decide whether it goes upstream; that is a human call taken later on the
  accumulated batch. What you DO enforce: never let an agent pin surprising
  native behaviour as golden without opening that issue. The corpus becomes the
  Ruby backend's specification, so a silently pinned bug stops being a bug and
  becomes a required behaviour of this gem.
- #254's forecast comes back "stop". That is the whole point of the test-drive;
  do not start Milestone 2 on your own.
