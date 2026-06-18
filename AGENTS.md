# AGENTS.md

## Project

Beryl is a Ruby gem for graphable workflows over focused state. It should stay Ruby-native: plain
blocks, explicit values, operator composition, and no fake IO/effect DSL.

## Repository rules

- Read `README.md` before changing the design.
- Keep public syntax small: `Task[...]`, `Workflow[...]`, `>>`, `&`, branch/rescue helpers.
- Do not introduce `Effect`, `reads`, `writes`, `requires`, or `returns` DSLs.
- Task bodies receive a focus object and access state inside the block.
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
