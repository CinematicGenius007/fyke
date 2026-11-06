#!/usr/bin/env python3
"""Runs the official Python MCP client against `rss mcp`.

Usage: py_mcp.py <path-to-rss>     (needs: pip install mcp, and RSS_HOME with data)
"""
import asyncio, json, os, sys
from mcp import ClientSession, StdioServerParameters, stdio_client

async def main():
    server = StdioServerParameters(command=os.path.abspath(sys.argv[1]), args=["mcp"], env=dict(os.environ))
    async with stdio_client(server) as (read, write):
        async with ClientSession(read, write) as session:
            info = await session.initialize()
            print("connected:", info)
            tools = await session.list_tools()
            names = [t.name for t in tools.tools]
            assert "entries_search" in names and "feeds_remove" not in names, names
            print("tools:", len(names))

            result = await session.call_tool("feeds_list", {})
            assert not result.is_error if hasattr(result, "is_error") else not result.isError
            body = json.loads(result.content[0].text)
            assert body["trust"] == "untrusted-feed-content"
            print("tool call: ok")

            resources = await session.list_resources()
            templates = await session.list_resource_templates()
            schema = await session.read_resource("rss://schema")
            assert "CREATE TABLE entries" in schema.contents[0].text
            print("resources:", len(resources.resources), "templates:", len(getattr(templates, "resource_templates", getattr(templates, "resourceTemplates", []))))

            prompts = await session.list_prompts()
            prompt = await session.get_prompt("catch-up-on-topic", {"topic": "Zig"})
            assert prompt.messages[0].content.text.endswith("Topic: Zig")
            print("prompts:", len(prompts.prompts))
            await session.send_ping()
            print("all checks passed")

asyncio.run(main())
