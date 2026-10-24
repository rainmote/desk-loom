#!/usr/bin/env python3
"""DeskLoom's local RPC transport. Never logs the private session token."""
import json
import pathlib
import sys
import urllib.error
import urllib.request


class RPCError(Exception):
    """An error safe to display without credentials or endpoint file contents."""


def endpoint_path():
    support = pathlib.Path.home() / "Library/Application Support"
    current = support / "DeskLoom/endpoint.json"
    legacy = support / "ComputerUsePrototype/endpoint.json"
    return current if current.is_file() or not legacy.is_file() else legacy


def read_endpoint():
    try:
        config = json.loads(endpoint_path().read_text())
    except FileNotFoundError:
        raise RPCError("DeskLoom is not running. Start it with 'dlm open'.") from None
    except (OSError, ValueError):
        raise RPCError("Cannot read DeskLoom's endpoint. Restart the app.") from None
    if (not isinstance(config, dict) or config.get("protocol_version") != 1
            or type(config.get("port")) is not int or not 0 < config["port"] < 65536
            or not isinstance(config.get("token"), str) or not config["token"]):
        raise RPCError("DeskLoom's endpoint is invalid. Restart the app.")
    return config


def call(method, params=None):
    """One authenticated loopback request. Actions are never retried."""
    config = read_endpoint()
    request = urllib.request.Request(
        f"http://127.0.0.1:{config['port']}/rpc",
        json.dumps({"method": method, "params": params or {}}).encode(),
        {"Content-Type": "application/json", "Authorization": "Bearer " + config["token"]})
    try:
        # The native endpoint is always local, independent of proxy environment.
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=15) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        code = error.code
        error.close()
        raise RPCError(f"DeskLoom rejected the request (HTTP {code}).") from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise RPCError("Cannot reach DeskLoom. The request was not retried; check the app's state.") from None
    except ValueError:
        raise RPCError("DeskLoom returned an invalid response.") from None
    if not isinstance(result, dict) or type(result.get("ok")) is not bool:
        raise RPCError("DeskLoom returned an invalid response.")
    # Do not expose the session token even if a response accidentally echoes it.
    return json.loads(json.dumps(result).replace(config["token"], "[redacted]"))


def json_object(value):
    try:
        result = json.loads(value)
    except ValueError:
        raise RPCError("RPC params must be valid JSON.") from None
    if not isinstance(result, dict):
        raise RPCError("RPC params must be a JSON object.")
    return result


def print_result(result):
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result.get("ok") else 1


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) > 2:
        print("Usage: rpc.py [METHOD [JSON_PARAMS]]", file=sys.stderr)
        return 2
    try:
        return print_result(call(argv[0] if argv else "status", json_object(argv[1]) if len(argv) == 2 else {}))
    except RPCError as error:
        print(f"DeskLoom: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
