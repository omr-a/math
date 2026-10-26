---
name: screenshot-to-code
description: Run or work on screenshot-to-code, an app that turns screenshots, mockups, Figma designs and screen recordings into HTML/Tailwind, React, Vue, Bootstrap or Ionic code using LLMs. Use when the user wants to convert a UI image or recording into code, or to run/modify this app.
---

# screenshot-to-code

The app lives in `screenshot-to-code/` at the repo root
(vendored from github.com/abi/screenshot-to-code — see `screenshot-to-code/UPSTREAM.txt`).
Read `screenshot-to-code/CLAUDE.md` and `screenshot-to-code/README.md` first.

Run it:

- Backend (FastAPI, port 7001): `cd screenshot-to-code/backend && poetry install && poetry run playwright install chromium && poetry run uvicorn main:app --reload --port 7001`
- Frontend (Vite, port 5173): `cd screenshot-to-code/frontend && pnpm install && pnpm dev`, then open `http://localhost:5173` (not 127.0.0.1).
- Needs at least one of `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY` in `backend/.env`
  (Gemini and `REPLICATE_API_KEY` recommended). Never commit `.env`.

After code changes: `cd backend && poetry run pytest && poetry run pyright`; `cd frontend && pnpm lint`.
