# /// script
# requires-python = ">=3.9"
# dependencies = ["jupyter_client>=8.0"]
# ///
"""nbx kernel sidecar.

Bridges Neovim and a Jupyter kernel. Neovim writes one JSON request per line
to stdin ({"id", "method", "params"}) and reads JSON lines from stdout: either
replies ({"id", "result" | "error"}) or events ({"event", ...}).

The kernel process inherits this process's stdout, so the protocol stream is
moved to a private descriptor and fd 1 is pointed at stderr. Everything the
kernel prints outside the Jupyter protocol ends up in the nbx log.
"""

from __future__ import annotations

import asyncio
import inspect
import json
import os
import signal
import sys

PROTO = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")
os.dup2(2, 1)

from jupyter_client.kernelspec import KernelSpec, KernelSpecManager  # noqa: E402
from jupyter_client.manager import AsyncKernelManager  # noqa: E402


def send(obj: dict) -> None:
    PROTO.write(json.dumps(obj, ensure_ascii=False) + "\n")
    PROTO.flush()


def log(*args) -> None:
    print("[nbx]", *args, file=sys.stderr, flush=True)


async def maybe_await(value):
    if inspect.isawaitable(value):
        return await value
    return value


class Sidecar:
    def __init__(self) -> None:
        self.km: AsyncKernelManager | None = None
        self.kc = None
        self.execs: dict[str, dict] = {}  # kernel msg_id -> {"id", "reply", "idle"}
        self.loops: list[asyncio.Task] = []
        self.busy_restarting = False

    # -- lifecycle ---------------------------------------------------------

    def _start_loops(self) -> None:
        self.loops = [
            asyncio.create_task(self._guard(self._iopub_loop())),
            asyncio.create_task(self._guard(self._shell_loop())),
            asyncio.create_task(self._guard(self._stdin_loop())),
            asyncio.create_task(self._guard(self._watch())),
        ]

    async def _stop_loops(self) -> None:
        for t in self.loops:
            t.cancel()
        for t in self.loops:
            try:
                await t
            except BaseException:
                pass
        self.loops = []

    async def _guard(self, coro) -> None:
        try:
            await coro
        except asyncio.CancelledError:
            raise
        except Exception as e:  # keep the sidecar alive, but say what happened
            log("loop failed:", repr(e))

    async def _stop(self) -> None:
        await self._stop_loops()
        self.execs.clear()
        if self.kc is not None:
            try:
                self.kc.stop_channels()
            except Exception:
                pass
            self.kc = None
        if self.km is not None:
            try:
                await self.km.shutdown_kernel(now=True)
            except Exception as e:
                log("shutdown failed:", repr(e))
            self.km = None

    def _need(self):
        if self.km is None or self.kc is None:
            raise RuntimeError("no kernel is running")
        return self.km, self.kc

    # -- rpc ---------------------------------------------------------------

    async def rpc_kernelspecs(self) -> dict:
        specs = KernelSpecManager().get_all_specs()
        return {
            name: {
                "display_name": s["spec"].get("display_name", name),
                "language": s["spec"].get("language", ""),
            }
            for name, s in specs.items()
        }

    async def rpc_start(
        self,
        argv=None,
        name=None,
        cwd=None,
        display_name=None,
        env=None,
        unset=None,
        timeout=60,
    ) -> dict:
        await self._stop()
        if argv:
            km = AsyncKernelManager()
            km._kernel_spec = KernelSpec(
                argv=list(argv), display_name=display_name or "Python", language="python"
            )
        else:
            km = AsyncKernelManager(kernel_name=name or "python3")
        kenv = os.environ.copy()
        for key in unset or []:
            kenv.pop(key, None)
        kenv.update(env or {})
        send({"event": "status", "state": "starting"})
        await km.start_kernel(cwd=cwd or None, env=kenv)
        kc = km.client()
        kc.start_channels()
        try:
            await kc.wait_for_ready(timeout=timeout)
            reply = await kc.kernel_info(reply=True, timeout=timeout)
        except BaseException:
            kc.stop_channels()
            try:
                await km.shutdown_kernel(now=True)
            except Exception:
                pass
            raise
        self.km, self.kc = km, kc
        self._start_loops()
        send({"event": "status", "state": "idle"})
        content = reply.get("content", {})
        return {
            "display_name": km.kernel_spec.display_name if km.kernel_spec else name,
            "language_info": content.get("language_info", {}),
            "banner": content.get("banner", ""),
        }

    async def rpc_execute(self, code: str, exec_id: str) -> None:
        _, kc = self._need()
        msg_id = await maybe_await(kc.execute(code, allow_stdin=True, stop_on_error=True))
        self.execs[msg_id] = {"id": exec_id, "reply": None, "idle": False}

    async def rpc_interrupt(self) -> None:
        km, _ = self._need()
        await km.interrupt_kernel()

    async def rpc_restart(self, timeout=60) -> None:
        km, kc = self._need()
        self.busy_restarting = True
        try:
            await self._stop_loops()
            self.execs.clear()
            send({"event": "status", "state": "starting"})
            await km.restart_kernel(now=True)
            await kc.wait_for_ready(timeout=timeout)
            self._start_loops()
            send({"event": "status", "state": "idle"})
        finally:
            self.busy_restarting = False

    async def rpc_input_reply(self, value: str) -> None:
        _, kc = self._need()
        kc.input(value)

    async def rpc_shutdown(self) -> None:
        await self._stop()
        send({"event": "status", "state": "dead"})

    # -- kernel channels -----------------------------------------------------

    def _finish(self, msg_id: str) -> None:
        rec = self.execs.get(msg_id)
        if rec is None or rec["reply"] is None or not rec["idle"]:
            return
        del self.execs[msg_id]
        reply = rec["reply"]
        pages = []
        for payload in reply.get("payload") or []:
            if payload.get("source") == "page":
                text = (payload.get("data") or {}).get("text/plain")
                if text:
                    pages.append(text)
        send(
            {
                "event": "done",
                "exec_id": rec["id"],
                "status": reply.get("status", "ok"),
                "execution_count": reply.get("execution_count"),
                "pages": pages,
            }
        )

    async def _iopub_loop(self) -> None:
        kc = self.kc
        while True:
            msg = await kc.get_iopub_msg(timeout=None)
            kind = msg["msg_type"]
            content = msg["content"]
            parent = msg.get("parent_header", {}).get("msg_id")
            rec = self.execs.get(parent)
            if kind == "status":
                state = content.get("execution_state")
                send({"event": "status", "state": state})
                if state == "idle" and rec is not None:
                    rec["idle"] = True
                    self._finish(parent)
                continue
            if kind == "update_display_data":
                send(
                    {
                        "event": "update_display",
                        "display_id": (content.get("transient") or {}).get("display_id"),
                        "data": content.get("data", {}),
                        "metadata": content.get("metadata", {}),
                    }
                )
                continue
            if rec is None:
                continue
            eid = rec["id"]
            if kind == "execute_input":
                send(
                    {
                        "event": "execute_input",
                        "exec_id": eid,
                        "execution_count": content.get("execution_count"),
                    }
                )
            elif kind == "stream":
                send(
                    {
                        "event": "output",
                        "exec_id": eid,
                        "output": {
                            "output_type": "stream",
                            "name": content.get("name", "stdout"),
                            "text": content.get("text", ""),
                        },
                    }
                )
            elif kind in ("display_data", "execute_result"):
                output = {
                    "output_type": kind,
                    "data": content.get("data", {}),
                    "metadata": content.get("metadata", {}),
                }
                if kind == "execute_result":
                    output["execution_count"] = content.get("execution_count")
                send(
                    {
                        "event": "output",
                        "exec_id": eid,
                        "output": output,
                        "display_id": (content.get("transient") or {}).get("display_id"),
                    }
                )
            elif kind == "error":
                send(
                    {
                        "event": "output",
                        "exec_id": eid,
                        "output": {
                            "output_type": "error",
                            "ename": content.get("ename", ""),
                            "evalue": content.get("evalue", ""),
                            "traceback": content.get("traceback", []),
                        },
                    }
                )
            elif kind == "clear_output":
                send({"event": "clear_output", "exec_id": eid, "wait": bool(content.get("wait"))})

    async def _shell_loop(self) -> None:
        kc = self.kc
        while True:
            msg = await kc.get_shell_msg(timeout=None)
            if msg["msg_type"] != "execute_reply":
                continue
            parent = msg.get("parent_header", {}).get("msg_id")
            rec = self.execs.get(parent)
            if rec is None:
                continue
            rec["reply"] = msg["content"]
            # An aborted request never goes busy/idle, so there is nothing to wait for.
            if msg["content"].get("status") == "aborted":
                rec["idle"] = True
            self._finish(parent)

    async def _stdin_loop(self) -> None:
        kc = self.kc
        while True:
            msg = await kc.get_stdin_msg(timeout=None)
            if msg["msg_type"] == "input_request":
                content = msg["content"]
                send(
                    {
                        "event": "input_request",
                        "prompt": content.get("prompt", ""),
                        "password": bool(content.get("password")),
                    }
                )

    async def _watch(self) -> None:
        while True:
            await asyncio.sleep(1.0)
            if self.km is None or self.busy_restarting:
                continue
            if not await self.km.is_alive():
                send({"event": "status", "state": "dead"})
                return

    # -- main loop -----------------------------------------------------------

    async def handle(self, msg: dict) -> None:
        mid = msg.get("id")
        try:
            fn = getattr(self, "rpc_" + str(msg.get("method")), None)
            if fn is None:
                raise RuntimeError(f"unknown method {msg.get('method')!r}")
            result = await fn(**(msg.get("params") or {}))
            if mid is not None:
                send({"id": mid, "result": result})
        except Exception as e:
            log("request failed:", repr(e))
            if mid is not None:
                send({"id": mid, "error": f"{type(e).__name__}: {e}"})

    async def run(self) -> None:
        loop = asyncio.get_running_loop()
        stop = asyncio.Event()
        for sig in (signal.SIGTERM, signal.SIGHUP):
            try:
                loop.add_signal_handler(sig, stop.set)
            except (NotImplementedError, RuntimeError):
                pass
        # The kernel is interrupted through its own process group. Ignore SIGINT
        # here so that an interrupt never takes the sidecar down with it.
        signal.signal(signal.SIGINT, signal.SIG_IGN)

        async def reader() -> None:
            while True:
                line = await loop.run_in_executor(None, sys.stdin.readline)
                if not line:
                    stop.set()
                    return
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except ValueError:
                    log("bad request:", line[:200])
                    continue
                asyncio.create_task(self.handle(msg))

        task = asyncio.create_task(reader())
        send({"event": "ready"})
        await stop.wait()
        task.cancel()
        await self._stop()


def main() -> None:
    try:
        asyncio.run(Sidecar().run())
    finally:
        # A reader thread may still be blocked on stdin; do not wait for it.
        os._exit(0)


if __name__ == "__main__":
    main()
