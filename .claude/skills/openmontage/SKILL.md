---
name: openmontage
description: Agentic video production with OpenMontage (explainers, trailers, animations, clips, reference-video remakes, narration, music, Remotion/Manim rendering). Use whenever the user asks to make, create, edit or produce any video or animated content.
---

# OpenMontage

The full OpenMontage project lives in `openmontage/` at the repo root
(vendored from github.com/calesthio/OpenMontage — see `openmontage/UPSTREAM.txt`).

Before doing anything:

1. `cd openmontage` — all paths in its docs are relative to that folder.
2. Read `openmontage/AGENT_GUIDE.md` in full and follow its routing rules
   (onboarding, reference-video workflow, Rule Zero: every production goes through
   a pipeline in `pipeline_defs/`, stage director skills in `skills/pipelines/`).
3. Provider/tool skills are in `openmontage/.claude/skills/` and `openmontage/.agents/skills/`;
   read the relevant one before calling a tool.
4. Setup: `pip install -r requirements.txt`, `cd remotion-composer && npm install`,
   and copy `.env.example` to `.env` for API keys (never commit `.env`).
