//! Grades a poker bot's postflop decisions in one heads-up hand.
//!
//! Usage: grade_hand <hand.json>     (prints one JSON object)
//!
//! Input:
//!   {"config": <SpotConfig, solved from the flop>,
//!    "iterations": 400, "target_exploit_pct": 0.5,
//!    "villain": 0|1, "pf_aggressor": 0|1|null,
//!    "profile": <query::PostflopStats>|null,        villain's postflop stats (optional)
//!    "queries": [{"id": "...", "path": ["check", "bet:50", "call", "card:6c", ...],
//!                 "combo": "JsJh", "chosen": "bet:33"}]}
//! Path steps and "chosen" are matched against the node's action labels: check, call, fold,
//! allin, bet:<pct>, raise:<pct> (the nearest size of that kind), or card:<card>.
//!
//! Output: per query, every action's label and the hero hand's EV and frequency, first against
//! the equilibrium ("gto"), then (with a profile) after locking the villain to his stats and
//! re-solving the hero's side ("exploit"). EVs are in the config's chip units.

use serde::Deserialize;
use serde_json::{json, Value};
use solver::query::PostflopStats;
use solver::store::Storage;
use solver::{PathStep, RunOptions, Solver, Spot, SpotConfig};
use std::sync::atomic::AtomicBool;
use std::sync::Arc;

#[derive(Deserialize)]
struct Query {
    id: String,
    path: Vec<String>,
    combo: String,
    chosen: String,
}

#[derive(Deserialize)]
struct Export {
    id: String,
    path: Vec<String>,
}

#[derive(Deserialize)]
struct Input {
    config: SpotConfig,
    #[serde(default = "default_iters")]
    iterations: u32,
    #[serde(default = "default_target")]
    target_exploit_pct: f64,
    #[serde(default)]
    villain: usize,
    #[serde(default)]
    pf_aggressor: Option<usize>,
    #[serde(default)]
    profile: Option<PostflopStats>,
    /// refuse (before allocating) a spot whose solver memory would exceed this many GB
    #[serde(default)]
    max_gb: Option<f64>,
    /// only report the memory estimate
    #[serde(default)]
    estimate_only: bool,
    queries: Vec<Query>,
    /// nodes (usually the start of a later street) whose reach-weighted ranges to report, so that
    /// street can be re-solved on its own with finer bet sizes
    #[serde(default)]
    exports: Vec<Export>,
}

fn default_iters() -> u32 { 400 }
fn default_target() -> f64 { 0.5 }

/// Index of the action a step names, among a node's labels.
fn pick(labels: &[String], step: &str) -> Option<usize> {
    let s = step.to_lowercase();
    let lower: Vec<String> = labels.iter().map(|l| l.to_lowercase()).collect();
    let find = |p: &str| lower.iter().position(|l| l.starts_with(p));
    match s.as_str() {
        "check" => find("check"),
        "call" => find("call"),
        "fold" => find("fold"),
        // without an all-in option, the largest bet or raise stands in for it
        "allin" => find("all-in").or_else(|| {
            labels.iter().enumerate().filter(|(_, l)| l.to_lowercase().starts_with("bet") || l.to_lowercase().starts_with("raise"))
                .max_by(|a, b| {
                    let amt = |l: &String| l.split_whitespace().nth(1).and_then(|x| x.parse::<f64>().ok()).unwrap_or(0.0);
                    amt(a.1).partial_cmp(&amt(b.1)).unwrap()
                }).map(|(i, _)| i)
        }),
        _ => {
            let (kind, pct) = s.split_once(':')?;
            let want: f64 = pct.parse().ok()?;
            // nearest size of that kind, by the "(NN%)" in the label; all-in counts as 1000%
            let mut best: Option<(usize, f64)> = None;
            for (i, l) in lower.iter().enumerate() {
                let p = if l.starts_with(kind) {
                    l.rsplit_once('(').and_then(|(_, r)| r.trim_end_matches(&['%', ')'][..]).parse::<f64>().ok())
                } else if l.starts_with("all-in") {
                    Some(1000.0)
                } else {
                    None
                };
                if let Some(p) = p {
                    let d = (p - want).abs();
                    if best.map_or(true, |(_, bd)| d < bd) {
                        best = Some((i, d));
                    }
                }
            }
            best.map(|(i, _)| i).or_else(|| find(kind))
        }
    }
}

fn walk(s: &Solver, steps: &[String]) -> Result<Vec<PathStep>, String> {
    let mut path: Vec<PathStep> = vec![];
    for step in steps {
        if let Some(card) = step.strip_prefix("card:") {
            path.push(PathStep::Card { card: card.to_string() });
            continue;
        }
        let v = s.node_view(&path)?;
        let labels: Vec<String> = v.actions.iter().map(|a| a.label.clone()).collect();
        let i = pick(&labels, step).ok_or(format!("no action {step:?} in {labels:?}"))?;
        path.push(PathStep::Action { index: i });
    }
    Ok(path)
}

/// Both players' ranges at a node, weighted by reach (range weight x strategy along the path).
fn export(s: &Solver, e: &Export) -> Result<Value, String> {
    let path = walk(s, &e.path)?;
    let v = s.node_view(&path)?;
    let mut ranges = vec![];
    for p in 0..2 {
        let hands = &v.players[p].hands;
        let max = hands.iter().map(|h| h.reach).fold(0f32, f32::max).max(1e-9);
        let toks: Vec<String> = hands.iter().filter(|h| h.reach / max >= 0.002)
            .map(|h| format!("{}:{:.4}", h.combo, h.reach / max)).collect();
        ranges.push(toks.join(","));
    }
    Ok(json!({"pot": v.pot, "put": v.put, "board": v.board, "oop": ranges[0], "ip": ranges[1]}))
}

fn answer(s: &Solver, q: &Query) -> Result<Value, String> {
    let mut path: Vec<PathStep> = vec![];
    for step in &q.path {
        if let Some(card) = step.strip_prefix("card:") {
            path.push(PathStep::Card { card: card.to_string() });
            continue;
        }
        let v = s.node_view(&path)?;
        let labels: Vec<String> = v.actions.iter().map(|a| a.label.clone()).collect();
        let i = pick(&labels, step).ok_or(format!("no action {step:?} in {labels:?}"))?;
        path.push(PathStep::Action { index: i });
    }
    let v = s.node_view(&path)?;
    let player = v.player.ok_or("not an action node")? as usize;
    let labels: Vec<String> = v.actions.iter().map(|a| a.label.clone()).collect();
    let chosen = pick(&labels, &q.chosen).ok_or(format!("no action {:?} in {labels:?}", q.chosen))?;
    let rev = format!("{}{}", &q.combo[2..4], &q.combo[0..2]);
    let h = v.players[player].hands.iter().find(|h| h.combo == q.combo || h.combo == rev)
        .ok_or(format!("{} not in range at this node", q.combo))?;
    let evs: Vec<Option<f32>> = (0..labels.len()).map(|i| h.evs.as_ref().and_then(|e| e.get(i).copied().flatten())).collect();
    let strat: Vec<f32> = h.strategy.clone().unwrap_or_default();
    Ok(json!({"actions": labels, "chosen": chosen, "evs": evs, "strategy": strat,
              "pot": v.pot, "player": player, "reach": h.reach}))
}

fn run(s: &mut Solver, iters: u32, target: f64) -> Value {
    let stop = AtomicBool::new(false);
    let t0 = std::time::Instant::now();
    let p = s.run(&RunOptions { max_iterations: iters, target_exploit_pct: target, check_every: 10 }, &stop, |_| {});
    s.ensure_symmetric();
    json!({"iteration": p.iteration, "exploit_pct_pot": p.exploit_pct_pot, "secs": t0.elapsed().as_secs_f64()})
}

fn main() {
    let path = std::env::args().nth(1).expect("usage: grade_hand <hand.json>");
    let input: Input = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).expect("input");
    let spot = Arc::new(Spot::new(input.config).expect("spot"));
    // compact 16-bit storage halves the memory; the estimate is checked before anything is allocated
    let gb = spot.arena_bytes_for(Storage::Compressed) as f64 / 1e9;
    if input.estimate_only || input.max_gb.map_or(false, |m| gb > m) {
        let err = if input.estimate_only { Value::Null } else { json!(format!("needs ~{gb:.1} GB, over the {:.1} GB cap", input.max_gb.unwrap())) };
        println!("{}", json!({"estimate_gb": gb, "error": err, "results": []}));
        return;
    }
    let mut s = Solver::with_storage(spot, Storage::Compressed);
    let gto_solve = run(&mut s, input.iterations, input.target_exploit_pct);
    let mut results: Vec<Value> = input.queries.iter().map(|q| {
        json!({"id": q.id, "gto": answer(&s, q).unwrap_or_else(|e| json!({"error": e}))})
    }).collect();
    let mut exports: Vec<Value> = input.exports.iter().map(|e| {
        json!({"id": e.id, "gto": export(&s, e).unwrap_or_else(|err| json!({"error": err}))})
    }).collect();
    let mut exploit_solve = Value::Null;
    if let Some(stats) = &input.profile {
        match s.lock_profile(input.villain, stats, input.pf_aggressor) {
            Ok(summary) => {
                // the villain is locked; continuing re-optimizes the hero's side against him
                exploit_solve = run(&mut s, input.iterations, input.target_exploit_pct);
                exploit_solve["locked"] = json!(summary.locked);
                for (r, q) in results.iter_mut().zip(&input.queries) {
                    r["exploit"] = answer(&s, q).unwrap_or_else(|e| json!({"error": e}));
                }
                for (x, e) in exports.iter_mut().zip(&input.exports) {
                    x["exploit"] = export(&s, e).unwrap_or_else(|err| json!({"error": err}));
                }
            }
            Err(e) => exploit_solve = json!({"error": e}),
        }
    }
    println!("{}", json!({"estimate_gb": gb, "gto_solve": gto_solve, "exploit_solve": exploit_solve, "results": results, "exports": exports}));
}
