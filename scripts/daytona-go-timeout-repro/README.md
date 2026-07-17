# Daytona Go SDK 60-second timeout repro

This standalone program tests the difference between synchronous command execution and Daytona's documented asynchronous process-session workflow. It pins the SDK revision containing the 60-second `http.Client` timeout from the original report.

The default run does two checks:

1. Runs a 70-second command synchronously with a longer sandbox execution timeout. This is a control that should expose the SDK's approximately 60-second HTTP client timeout.
2. Runs a separate 70-second command asynchronously, polls its status with short HTTP requests, verifies its exit code and completion marker, and prints `PASS`.

The program always attempts to delete its process session and sandbox, including after errors or `Ctrl-C`.

## Run

Go 1.25.4 or newer is required by the pinned SDK.

```sh
cd scripts/daytona-go-timeout-repro
export DAYTONA_API_KEY='...'
go run .
```

The first run downloads the pinned Go modules. Creating a Daytona sandbox may incur usage charges. A default run takes a little over two minutes because it runs both the synchronous control and asynchronous verification.

## Configuration

All settings are optional except `DAYTONA_API_KEY`:

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `DAYTONA_API_KEY` | required | Daytona API key read by the official SDK. |
| `DAYTONA_API_URL` | SDK default | Override the Daytona API endpoint when needed. |
| `DAYTONA_TARGET` | SDK default | Override the Daytona target/region when needed. |
| `DAYTONA_REPRO_DURATION` | `70s` | Command duration. Must be at least `61s`. |
| `DAYTONA_REPRO_SYNC` | `true` | Set to `false` to skip the synchronous control and test only the workaround. |
| `DAYTONA_REPRO_POLL_INTERVAL` | `2s` | Interval between async status requests. |

To test only the async workaround:

```sh
DAYTONA_REPRO_SYNC=false go run .
```

The synchronous control is diagnostic: if it does not time out, the program reports `NOT OBSERVED` and still proceeds. The final exit status is determined by the async workaround. `PASS` means the async command actually ran longer than 60 seconds, exited with code zero, and produced its unique completion marker.

## References

- [Daytona Go SDK getting started](https://www.daytona.io/docs/en/go-sdk/)
- [Daytona process sessions and async polling](https://www.daytona.io/docs/en/process-code-execution/)
- [Pinned SDK client timeout](https://github.com/daytona/clients/blob/88a17a89b6d1d7a3aa3c5249cc6fd402bbd0306d/sdk-go/pkg/daytona/client.go#L87)
