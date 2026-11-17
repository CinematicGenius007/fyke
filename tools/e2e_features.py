#!/usr/bin/env python3
"""Reader features through socket and MCP, with an isolated stand-in writer."""
import http.server
import json
import os
import shlex
import shutil
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time

FYKE = os.path.abspath(sys.argv[1])
TMP = tempfile.gettempdir() if os.name == "nt" else "/tmp"
passed = 0

def check(label, condition, detail=""):
    global passed
    assert condition, f"{label}: {detail}"
    passed += 1
    print("ok  ", label, flush=True)

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.path.startswith("/items/"): return self.thread(self.path[len("/items/"):])
        if self.path == "/hn": return self.reply(b'<rss version="2.0"><channel><title>HN</title>'
            b'<item><title>Kept</title><link>https://example.org/kept</link><comments>https://news.ycombinator.com/item?id=41</comments><description>x</description></item>'
            b'<item><title>Body</title><link>https://example.org/body</link><description>&lt;a href="https://news.ycombinator.com/item?id=42"&gt;Comments&lt;/a&gt;</description></item>'
            b'<item><title>Gone</title><link>https://example.org/gone</link><comments>https://news.ycombinator.com/item?id=43</comments><description>x</description></item>'
            b'<item><title>Elsewhere</title><link>https://example.org/else</link><comments>https://forum.example.org/t/1</comments><description>x</description></item>'
            b'</channel></rss>')
        paths = ["https://example.com/blog/a", "https://sub.example.com/blog/b", "https://example.com/blog/jobs/c", None]
        if self.path == "/many": paths = [f"https://example.com/many/{i}" for i in range(70)]
        if self.path == "/long": paths = [f"https://example.com/long/{i}" for i in range(3)]
        description = "storage "*10000 if self.path=="/long" else "Storage engine compiler news."
        items = "".join(f'<item><title>Storage engine {i}</title><guid>{i}</guid>' + (f'<link>{url}</link>' if url else '') + f'<description>{description}</description></item>' for i, url in enumerate(paths))
        body = f'<rss version="2.0"><channel><title>Engineering</title>{items}</channel></rss>'.encode()
        self.reply(body)

    def reply(self, body, status=200):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # A stand-in for the Algolia items API: thread 43 is missing.
    def thread(self, item):
        if item == "43": return self.reply(b'{"status":404}', 404)
        reply = lambda id, author, text, children=(): {"id":id,"type":"comment","author":author,"created_at_i":1700000000,"text":text,"children":list(children)}
        story = {"id":int(item),"type":"story","children":[
            reply(1,"ann","<p>First <a href=\"https://example.org/x\">link</a>",[reply(2,None,None,[reply(3,"bo","<i>Deep</i>")])]),
            reply(4,"cy","Second")]}
        self.reply(json.dumps(story).encode())

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

class WinUnixSocket:
    """Python's socket module has no AF_UNIX on Windows, though the system does, so this
    calls Winsock directly. It offers the few methods the checks use."""
    def __init__(self):
        import ctypes
        from ctypes import wintypes
        self.c = ctypes
        self.w = ctypes.WinDLL("ws2_32", use_last_error=True)
        self.w.socket.restype = ctypes.c_size_t
        self.w.socket.argtypes = [ctypes.c_int] * 3
        self.w.connect.argtypes = [ctypes.c_size_t, ctypes.c_void_p, ctypes.c_int]
        self.w.send.argtypes = [ctypes.c_size_t, ctypes.c_char_p, ctypes.c_int, ctypes.c_int]
        self.w.recv.argtypes = [ctypes.c_size_t, ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
        self.w.setsockopt.argtypes = [ctypes.c_size_t, ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        self.w.closesocket.argtypes = [ctypes.c_size_t]
        data = ctypes.create_string_buffer(400)
        if self.w.WSAStartup(0x0202, data) != 0: raise OSError("WSAStartup")
        self.h = self.w.socket(1, 1, 0)  # AF_UNIX, SOCK_STREAM
        if self.h == ctypes.c_size_t(-1).value: raise OSError("socket", ctypes.get_last_error())
    def fail(self, what):
        code = self.c.get_last_error()
        if code == 10060: raise TimeoutError(what)
        raise OSError(code, what)
    def settimeout(self, seconds):
        ms = self.c.c_uint32(int(seconds * 1000))
        for opt in (0x1005, 0x1006):  # SO_SNDTIMEO, SO_RCVTIMEO
            self.w.setsockopt(self.h, 0xFFFF, opt, self.c.byref(ms), 4)
    def connect(self, path):
        raw = path.encode()
        addr = self.c.create_string_buffer(2 + 108)
        addr[0:2] = (1).to_bytes(2, "little")
        addr[2:2 + len(raw)] = raw
        if self.w.connect(self.h, addr, 110) != 0: self.fail("connect")
    def sendall(self, data):
        while data:
            n = self.w.send(self.h, data, min(len(data), 1 << 20), 0)
            if n <= 0: self.fail("send")
            data = data[n:]
    def recv(self, n):
        buf = self.c.create_string_buffer(n)
        got = self.w.recv(self.h, buf, n, 0)
        if got < 0: self.fail("recv")
        return buf.raw[:got]
    def makefile(self, mode="r"):
        import io
        sock = self
        class R(io.RawIOBase):
            def readable(self): return True
            def readinto(self, b):
                data = sock.recv(len(b)); b[:len(data)] = data; return len(data)
        raw = io.BufferedReader(R())
        return raw if "b" in mode else io.TextIOWrapper(raw)
    def close(self): self.w.closesocket(self.h)
    def __enter__(self): return self
    def __exit__(self, *a): self.close()

def unix_socket():
    return WinUnixSocket() if os.name == "nt" else socket.socket(socket.AF_UNIX)


class SocketClient:
    def __init__(self, home, env):
        self.s = unix_socket()
        self.s.settimeout(15)
        self.s.connect(home + "/fyked.sock")
        self.f = self.s.makefile("rb")
    def call(self, method, **params):
        self.s.sendall((json.dumps({"jsonrpc":"2.0", "id":1, "method":method,"params":params})+"\n").encode())
        reply = json.loads(self.f.readline())
        if "error" in reply:
            data=reply["error"].get("data",{})
            if data.get("kind") in ("revision_conflict","in_use"): return data
            raise RuntimeError(reply["error"])
        return reply["result"]
    def close(self): self.f.close(); self.s.close()

class McpClient:
    def __init__(self, home, env):
        self.p = subprocess.Popen([FYKE,"mcp","--tier","manage"],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.send("initialize", {"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"features","version":"1"}})
    def send(self, method, params):
        self.p.stdin.write((json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params})+"\n").encode()); self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())
    def call(self, method, **params):
        # Owner settings deliberately stay out of the agent tool list.
        if method.startswith("config."):
            raw = SocketClient(self.home, self.env)
            try: return raw.call(method, **params)
            finally: raw.close()
        reply = self.send("tools/call", {"name":method.replace(".","_"),"arguments":params})
        if "error" in reply:
            data=reply["error"].get("data",{})
            if data.get("kind") in ("revision_conflict","in_use"): return data
            raise RuntimeError(reply["error"])
        result = reply["result"]
        if result.get("isError"):
            failure=json.loads(result["content"][0]["text"])
            data=failure.get("data",{})
            if data.get("kind") in ("revision_conflict","in_use"): return data
            raise RuntimeError(result)
        return json.loads(result["content"][0]["text"])["result"]
    def close(self): self.p.stdin.close(); self.p.wait(timeout=10); self.p.stdout.close(); self.p.stderr.close()

def expect_error(fn):
    try: fn()
    except RuntimeError: return True
    return False

def wait_job(call, job, status=None):
    end = time.monotonic()+15
    while time.monotonic()<end:
        row = next(r for r in call("jobs.list")["items"] if r["id"]==job["id"])
        if row["status"] in ("done","failed","cancelled"):
            if status: check("job " + status, row["status"]==status, row)
            return row
        time.sleep(.03)
    raise AssertionError("job did not finish")

server = Server(("127.0.0.1",0), Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()

for client_type in (SocketClient, McpClient):
    home = tempfile.mkdtemp(prefix="fyke-f-",dir=TMP)
    writer = home+"/standin.py"
    mode = home+"/mode"
    with open(mode,"w") as f: f.write("good")
    with open(writer,"w") as f:
        f.write('''import json, sys, time, os
mode=open(sys.argv[1]).read().strip()
with open(sys.argv[1]+".pid","w") as f: f.write(str(os.getpid()))
prompt=sys.stdin.read()
sources=json.loads(prompt.split("UNTRUSTED SOURCES JSON:\\n")[1].split("\\nEND SOURCES")[0])
assert len(sources)<=60 and sum(len(s["text"]) for s in sources)<=120000
with open(sys.argv[1]+".calls","a") as f: f.write("called\\n")
if mode=="closed": os.close(1); os.close(2); time.sleep(30)
if mode=="slow": time.sleep(30)
if mode=="huge": print("x"*(2<<20)); sys.exit()
ids=[999999] if mode=="invalid" else [sources[0]["id"]]
print(json.dumps({"title":"Morning brief","sections":[{"heading":"News","claims":[{"text":"Storage news.","sources":ids}]}]}))
''')
    command = subprocess.list2cmdline([sys.executable,writer,mode]) if os.name=="nt" else shlex.join([sys.executable,writer,mode])
    env = dict(os.environ,FYKE_HOME=home,FYKE_WRITER_CMD=command,FYKE_HN_ITEMS_URL=f"http://127.0.0.1:{server.server_address[1]}/items/")
    # Stand-in adapters log each call, so probe counts and the profile they ran with are
    # observable without installed agents. Codex is always signed in; Claude Code is
    # signed in only when its profile folder holds a `signed-in` file.
    if os.name != "nt":
        os.mkdir(home+"/bin")
        for name in ("codex", "claude"):
            executable = home+"/bin/"+name
            log = shlex.quote(home+"/"+name+".probes")
            with open(executable,"w") as f:
                f.write("#!/bin/sh\n"
                        f"printf '%s|%s\\n' \"$*\" \"$CLAUDE_CONFIG_DIR\" >> {log}\n"
                        "case \"$*\" in\n"
                        "  --version) printf 'fixture-version\\n' ;;\n"
                        "  'auth status') if [ -f \"$CLAUDE_CONFIG_DIR/signed-in\" ]; then echo '{\"loggedIn\": true}';"
                        " else echo '{\"loggedIn\": false}'; fi ;;\n"
                        "esac\n")
            os.chmod(executable,0o700)
        env["PATH"] = home+"/bin"+os.pathsep+env.get("PATH","")
    def probes(name, what="--version"):
        return [line.rstrip("\n").split("|") for line in open(home+"/"+name+".probes") if line.startswith(what+"|")]

    with open(home+"/config.json","w") as f: json.dump({"auto_poll":False,"full_text":False},f)
    client = None
    def cli(*args): return subprocess.run([FYKE,*args],env=env,capture_output=True,text=True,timeout=30)
    def set_mode(value):
        with open(mode,"w") as f: f.write(value)
    try:
        check("daemon starts",cli("status").returncode==0)
        client = client_type(home,env)
        client.home=home; client.env=env
        call = client.call
        print("Transport:",client_type.__name__,flush=True)
        folder = call("folders.add",name="Engineering")["id"]
        child = call("folders.add",name="Storage",parent_id=folder)["id"]
        feed = call("feeds.add",url=f"http://127.0.0.1:{server.server_address[1]}/feed",allow_private_network=True)["id"]
        call("feeds.update",id=feed,folder_id=child)
        all_entries=call("entries.list")["items"]
        ids=[e["id"] for e in all_entries]
        check("ingested",len(ids)==4)
        rule={"folders":[folder],"state":"unread","words":"storage engine","host":"example.com","subdomains":True,"path_prefix":"/blog/","exclude_path_prefix":["/blog/jobs/"]}
        preview=call("views.preview",rule=rule,limit=1)
        check("preview count and cursor",preview["total"]==2 and len(preview["items"])==1 and preview["next_cursor"])
        page=call("views.preview",rule=rule,before=preview["next_cursor"])
        check("keyset page",len(page["items"])==1 and page["items"][0]["id"]!=preview["items"][0]["id"])
        for bad in ({"evil":"SELECT"},{"feeds":[9999]},{"words":""},{"within_days":0}):
            check("invalid rule",expect_error(lambda:call("views.preview",rule=bad)))
        check("literal words",call("views.preview",rule={"words":"storage OR nonexistent"})["total"]==0)
        view=call("views.put",name="Engineering",rule=rule)
        vid=view["id"]
        check("view get sentence", "Engineering" in call("views.get",id=vid)["sentence"])
        check("view list counts",call("views.list")["items"][0]["total"]==2)
        check("view entry list",len(call("entries.list",view_id=vid)["items"])==2)
        check("ad hoc entry list",len(call("entries.list",rule=rule)["items"])==2)
        check("view conflict",call("views.put",id=vid,name="Other",rule={},expected_revision=0)["kind"]=="revision_conflict")
        call("views.put",id=vid,name="Engineering",rule=rule,expected_revision=1)
        call("views.move",id=vid,position=5)
        old=call("entries.mark",id=ids[0],later=True)["previous"]
        check("previous later state",old["later"] is False)
        check("later list",len(call("entries.list",rule={"state":"later"})["items"])==1)
        call("entries.mark",id=ids[0],later=old["later"])
        previous=call("entries.mark_many",ids=ids,read=True,starred=True,later=True)["previous"]
        check("bulk previous",len(previous)==4 and all(not p["read"] for p in previous))
        for old in previous: call("entries.mark",**old)
        check("bulk invalid atomic",expect_error(lambda:call("entries.mark_many",ids=[ids[0],9999],read=True)) and not call("entries.get",id=ids[0])["read"])
        recipes=call("recipes.list")["items"]
        check("built in recipe",recipes[0]["name"]=="Morning brief")
        original=call("recipes.get",id=1,revision=1)
        recipe=call("recipes.put",name="Custom",text="Be concise",note="First")
        check("recipe conflict",call("recipes.put",id=recipe["id"],name="Custom",text="Edited",expected_revision=0)["kind"]=="revision_conflict")
        call("recipes.put",id=1,name="Morning brief",text="Changed",expected_revision=1)
        call("recipes.reset",id=1,expected_revision=2)
        check("recipe history",len(call("recipes.history",id=1)["items"])==3 and call("recipes.get",id=1)["text"]==original["text"])
        writers=call("writers.list")["items"]
        check("writer detection",{w["writer"] for w in writers}=={"codex","claude"})
        check("writer probes timestamped",all(isinstance(w["checked_at"],int) for w in writers))
        check("writer list cached",call("writers.list")["items"]==writers)
        if os.name != "nt":
            check("lazy probes run once",all(len(probes(name))==1 for name in ("codex","claude")))
        refreshed = call("writers.check",writer="codex")
        check("writer probe",refreshed["writer"]=="codex")
        cached = call("writers.list")["items"]
        check("explicit check updates cache",next(w for w in cached if w["writer"]=="codex")["checked_at"]
              ==refreshed["checked_at"])
        if os.name != "nt":
            check("only checked adapter reprobed",len(probes("codex"))==2 and len(probes("claude"))==1)
            claude=next(w for w in cached if w["writer"]=="claude")
            check("signed out is not available",claude["installed"] and claude["signed_in"] is False and
                  not claude["available"] and "Not signed in" in claude["problem"])
            check("codex sign-in checked",refreshed["signed_in"] and refreshed["available"] and probes("codex","login status"))
            profile=os.path.join(home,"claude-profile"); os.mkdir(profile)
            open(os.path.join(profile,"signed-in"),"w").close()
            call("config.set",ai={"writer":"codex"})
            call("config.set",ai={"claude_profile":profile})
            ai=call("config.get")["ai"]
            check("ai settings merge",ai["writer"]=="codex" and ai["claude_profile"]==profile and "codex" in ai["checks"])
            claude=next(w for w in call("writers.list")["items"] if w["writer"]=="claude")
            check("profile change rechecks",len(probes("claude"))==2 and claude["available"] and claude["profile"]==profile)
            check("profile reaches claude",probes("claude","auth status")[-1][1]==profile)
            try:
                call("config.set",ai={"claude_profile":"relative/folder"}); refused=False
            except RuntimeError: refused=True
            check("relative profile refused",refused)
            try:
                call("config.set",ai={"claude_profile":os.path.join(home,"missing")}); refused=False
            except RuntimeError: refused=True
            check("missing profile refused",refused and call("config.get")["ai"]["claude_profile"]==profile)
            call("config.set",ai={"claude_profile":""})
            check("profile cleared","claude_profile" not in call("config.get")["ai"])

        call("config.set",ai={"writer":"claude"})
        check("writer setting",call("config.get")["ai"]["writer"]=="claude")
        job=wait_job(call,call("briefs.run",view_id=vid),"done")
        artifact=call("briefs.get",id=job["artifact_id"])
        check("brief provenance",artifact["writer"]=="claude" and artifact["input_count"]==2 and artifact["recipe_revision"]==3 and artifact["sources"] and artifact["body_blocks"])
        listed=len(call("briefs.list")["items"])
        trial=wait_job(call,call("briefs.try",view_id=vid,text="Try this"),"done")
        check("try unlisted",trial["artifact_id"] and len(call("briefs.list")["items"])==listed)
        check("trial text snapshot",call("briefs.get",id=trial["artifact_id"])["recipe_text"]=="Try this")
        answer=wait_job(call,call("ask.run",view_id=vid,question="What changed?"),"done")
        check("cited answer",call("answers.get",id=answer["artifact_id"])["question"]=="What changed?")
        calls_before = len(open(mode+".calls").readlines())
        empty=wait_job(call,call("briefs.run",rule={"words":"absentword"}),"done")
        check("empty never calls writer",len(open(mode+".calls").readlines())==calls_before)
        check("empty selection",empty["artifact_id"] is None)
        calls_before = len(open(mode+".calls").readlines())
        set_mode("invalid")
        bad=wait_job(call,call("briefs.run",view_id=vid),"failed")
        check("citation failure",bad["error"]=="InvalidCitation")
        check("validation retries once",len(open(mode+".calls").readlines())==calls_before+2)
        set_mode("closed")
        closed=wait_job(call,call("briefs.run",view_id=vid,timeout_seconds=1),"failed")
        check("closed streams keep deadline",closed["error"]=="WriterTimeout")
        set_mode("slow")
        slow=call("briefs.run",view_id=vid,timeout_seconds=1)
        check("timeout bounded",wait_job(call,slow,"failed")["error"]=="WriterTimeout")
        cancel=call("briefs.run",view_id=vid)
        time.sleep(.2)
        check("cancel",call("jobs.cancel",id=cancel["id"])["status"]=="cancelled")
        wait_job(call,cancel,"cancelled")
        set_mode("huge")
        huge=wait_job(call,call("briefs.run",view_id=vid),"failed")
        check("output cap",huge["error"]=="OutputTooLarge")
        set_mode("good")
        many=call("feeds.add",url=f"http://127.0.0.1:{server.server_address[1]}/many",allow_private_network=True)["id"]
        bounded=wait_job(call,call("briefs.run",rule={"feeds":[many]}),"done")
        bounded_artifact=call("briefs.get",id=bounded["artifact_id"])
        check("bounded selection",bounded_artifact["input_count"]==60 and bounded_artifact["omitted_count"]==10)
        long_feed=call("feeds.add",url=f"http://127.0.0.1:{server.server_address[1]}/long",allow_private_network=True)["id"]
        long_job=wait_job(call,call("briefs.run",rule={"feeds":[long_feed]}),"done")
        long_artifact=call("briefs.get",id=long_job["artifact_id"])
        check("text selection cap",long_artifact["input_count"]==2 and long_artifact["omitted_count"]==1)
        set_mode("slow")
        recovering=call("briefs.run",view_id=vid)
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            state=next(j for j in call("jobs.list")["items"] if j["id"]==recovering["id"])["status"]
            if state=="running" and os.path.exists(mode+".pid"): break
            time.sleep(.03)
        time.sleep(.15)
        child_pid=int(open(mode+".pid").read())
        client.close(); client=None
        check("restart stops daemon",cli("daemon","stop").returncode==0)
        # On Windows the writer is usually gone already: its job object ends it with the daemon.
        try: os.kill(child_pid,9 if os.name!="nt" else 15)
        except OSError: pass
        set_mode("good")
        check("restart starts daemon",cli("status").returncode==0)
        client=client_type(home,env);client.home=home;client.env=env;call=client.call
        recovered=wait_job(call,recovering,"done")
        check("durable lease recovery",recovered["attempts"]==2 and recovered["artifact_id"] is not None)
        check("recovery publishes once",sum(b["id"]==recovered["artifact_id"] for b in call("briefs.list")["items"])==1)
        routine=call("routines.put",name="Tidy",view_id=vid,schedule={"kind":"manual"},actions=[{"kind":"mark_read"},{"kind":"star"},{"kind":"tag","tag":"routine-test"},{"kind":"notify"},{"kind":"brief","recipe_id":1}])
        rid=routine["id"]
        check("routine get list",call("routines.get",id=rid)["id"]==rid and len(call("routines.list")["items"])==1)
        check("dry run",len(call("routines.dry_run",id=rid)["days"])==7)
        check("view in use",call("views.remove",id=vid)["kind"]=="in_use")
        run=wait_job(call,call("routines.run",id=rid),"done")
        runs=call("routines.runs",id=rid)["items"]
        check("captured before actions",len(runs[0]["matches"])==2 and len(runs[0]["results"])==5)
        check("routine state",call("views.list")["items"][0]["total"]==0)
        check("routine notifications",any(e["type"]=="routine.notify" for e in call("events.since")["items"]))
        wait_job(call,{"id":runs[0]["results"][-1]["job_id"]},"done")
        check("routine revision conflict",call("routines.put",id=rid,name="Tidy",view_id=vid,schedule={"kind":"daily","time":"09:00"},actions=[{"kind":"notify"}],expected_revision=0)["kind"]=="revision_conflict")
        again=wait_job(call,call("routines.run",id=rid),"done")
        check("routine watermark",call("routines.runs",id=rid)["items"][0]["matches"]==[])
        call("routines.put",id=rid,name="Tidy",view_id=vid,schedule={"kind":"weekly","time":"09:00","days":[1,3]},actions=[{"kind":"notify"}],expected_revision=1)
        check("next local run",call("routines.get",id=rid)["next_run_at"] is not None)
        call("views.remove",id=vid,detach=True)
        check("detach disables routine",call("routines.get",id=rid)["enabled"]==0)
        call("routines.remove",id=rid)
        check("removed definitions",not call("routines.list")["items"] and not call("views.list")["items"])
        hn = call("feeds.add",url=f"http://127.0.0.1:{server.server_address[1]}/hn",allow_private_network=True)["id"]
        stories = {e["title"]:e["id"] for e in call("entries.list",feed_id=hn)["items"]}
        check("discussion from comments",call("entries.get",id=stories["Kept"])["discussion_url"]=="https://news.ycombinator.com/item?id=41")
        check("discussion from body",call("entries.get",id=stories["Body"])["discussion_url"]=="https://news.ycombinator.com/item?id=42")
        check("other discussion kept",call("entries.get",id=stories["Elsewhere"])["discussion_url"]=="https://forum.example.org/t/1")
        thread = call("entries.discussion",id=stories["Kept"])
        check("thread in reading order",[(c["id"],c["depth"]) for c in thread["comments"]]==[(1,0),(2,1),(3,2),(4,0)] and not thread["truncated"],thread)
        check("thread as blocks",thread["comments"][0]["blocks"][0]["t"]=="p" and thread["comments"][1]["author"] is None and thread["comments"][1]["blocks"]==[])
        check("thread address",thread["url"]=="https://news.ycombinator.com/item?id=41" and thread["trust"]=="untrusted-feed-content")
        check("thread unavailable",expect_error(lambda:call("entries.discussion",id=stories["Gone"])))
        check("no thread",expect_error(lambda:call("entries.discussion",id=stories["Elsewhere"])))
    finally:
        if client: client.close()
        cli("daemon","stop")
        if sys.exc_info()[0] and os.path.exists(home+"/fyked.log"):
            print(open(home+"/fyked.log").read()[-4000:])
        shutil.rmtree(home,ignore_errors=True)
server.shutdown()
print(f"\n{passed} checks passed")
