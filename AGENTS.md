# AGENTS.md

## Project

Beryl is a Ruby gem for graphable workflows over focused state. The **surface API** stays
Ruby-native: plain blocks, explicit values, operator composition, and no user-facing IO/effect DSL.
Under the surface, beryl executes on a single substrate — the darkcore Effect tree (Freer monad).
darkcore is a required runtime dependency; `Beryl::EffectTree` is the one and only execution path.

## Repository rules

- Read `README.md` before changing the design.
- Keep public syntax small: `Task[...]`, `Workflow[...]`, `>>`, `&`, branch/rescue helpers.
- Do not expose `Effect`, `reads`, `writes`, `requires`, or `returns` DSLs in the **surface** API.
  The darkcore Effect tree is an internal substrate, not something users write against directly.
- Task bodies receive a focus object and access state inside the block.
- All combinators (Sequence / Parallel / Branch / Rescue) execute via `Beryl::EffectTree.run`. Do
  not reintroduce a second, native execution path alongside the Effect tree.
- Prefer real Ruby code over pseudo-code.
- Keep the gem buildable with `gem build beryl.gemspec`.

## Commands

```sh
bundle install
bundle exec rake
bundle exec rubocop
npm install
npm run format:check
```

## Before handing off

Run tests, lint, formatter check, and gem build when the environment supports them.
