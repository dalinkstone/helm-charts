package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/daytona/clients/sdk-go/pkg/daytona"
	"github.com/daytona/clients/sdk-go/pkg/options"
)

const (
	defaultDuration     = 70 * time.Second
	defaultPollInterval = 2 * time.Second
	minimumDuration     = 61 * time.Second
)

type config struct {
	duration     time.Duration
	pollInterval time.Duration
	runSync      bool
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "\nFAIL: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	if strings.TrimSpace(os.Getenv("DAYTONA_API_KEY")) == "" {
		return errors.New("DAYTONA_API_KEY is required")
	}

	cfg, err := loadConfig()
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	fmt.Printf("Daytona Go SDK timeout repro\n")
	fmt.Printf("  command duration: %s (>60s)\n", cfg.duration)
	fmt.Printf("  synchronous demonstration: %t\n", cfg.runSync)
	fmt.Printf("  asynchronous poll interval: %s\n\n", cfg.pollInterval)

	client, err := daytona.NewClient()
	if err != nil {
		return fmt.Errorf("create Daytona client: %w", err)
	}
	defer func() {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if err := client.Close(cleanupCtx); err != nil {
			fmt.Fprintf(os.Stderr, "WARN: close Daytona client: %v\n", err)
		}
	}()

	fmt.Println("Creating Daytona sandbox...")
	sandbox, err := client.Create(ctx, nil, options.WithTimeout(5*time.Minute))
	if err != nil {
		return fmt.Errorf("create sandbox: %w", err)
	}
	fmt.Printf("Created sandbox %s\n", sandbox.ID)

	defer func() {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		fmt.Printf("Cleaning up sandbox %s...\n", sandbox.ID)
		if err := sandbox.Delete(cleanupCtx); err != nil {
			fmt.Fprintf(os.Stderr, "WARN: delete sandbox %s: %v\n", sandbox.ID, err)
			return
		}
		fmt.Println("Sandbox cleanup requested")
	}()

	if cfg.runSync {
		demonstrateSyncTimeout(ctx, sandbox, cfg.duration)
	}

	if err := verifyAsyncWorkaround(ctx, sandbox, cfg); err != nil {
		return err
	}

	fmt.Printf("\nPASS: async session command completed after %s without a single HTTP request staying open for the full command\n", cfg.duration)
	return nil
}

func loadConfig() (config, error) {
	duration, err := durationEnv("DAYTONA_REPRO_DURATION", defaultDuration)
	if err != nil {
		return config{}, err
	}
	if duration < minimumDuration {
		return config{}, fmt.Errorf("DAYTONA_REPRO_DURATION must be at least %s to test the 60-second boundary", minimumDuration)
	}

	pollInterval, err := durationEnv("DAYTONA_REPRO_POLL_INTERVAL", defaultPollInterval)
	if err != nil {
		return config{}, err
	}
	if pollInterval <= 0 {
		return config{}, errors.New("DAYTONA_REPRO_POLL_INTERVAL must be greater than zero")
	}

	runSync, err := boolEnv("DAYTONA_REPRO_SYNC", true)
	if err != nil {
		return config{}, err
	}

	return config{duration: duration, pollInterval: pollInterval, runSync: runSync}, nil
}

func durationEnv(name string, fallback time.Duration) (time.Duration, error) {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback, nil
	}
	duration, err := time.ParseDuration(value)
	if err != nil {
		return 0, fmt.Errorf("parse %s=%q: %w", name, value, err)
	}
	return duration, nil
}

func boolEnv(name string, fallback bool) (bool, error) {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		return false, fmt.Errorf("parse %s=%q: %w", name, value, err)
	}
	return parsed, nil
}

func demonstrateSyncTimeout(ctx context.Context, sandbox *daytona.Sandbox, duration time.Duration) {
	fmt.Println("\n[1/2] Synchronous control: one request waits for the entire command")
	started := time.Now()
	response, err := sandbox.Process.ExecuteCommand(
		ctx,
		longCommand("sync", duration),
		options.WithExecuteTimeout(duration+30*time.Second),
	)
	elapsed := time.Since(started).Round(time.Millisecond)

	if err != nil {
		fmt.Printf("OBSERVED: synchronous request failed after %s: %v\n", elapsed, err)
		if elapsed >= 55*time.Second && elapsed < duration {
			fmt.Println("PASS (control): failure occurred near the SDK's 60-second HTTP client timeout")
		} else {
			fmt.Println("WARN (control): failure timing was not near 60 seconds; inspect the error above")
		}
		return
	}

	fmt.Printf("NOT OBSERVED: synchronous command returned after %s (exit code %d)\n", elapsed, response.ExitCode)
	fmt.Println("INFO: the pinned SDK/API path did not reproduce the expected client timeout; the async test still verifies the workaround")
}

func verifyAsyncWorkaround(ctx context.Context, sandbox *daytona.Sandbox, cfg config) error {
	fmt.Println("\n[2/2] Async workaround: start immediately, then poll with short requests")
	sessionID := fmt.Sprintf("go-timeout-repro-%d", time.Now().UnixNano())
	if err := sandbox.Process.CreateSession(ctx, sessionID); err != nil {
		return fmt.Errorf("create process session: %w", err)
	}

	defer func() {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if err := sandbox.Process.DeleteSession(cleanupCtx, sessionID); err != nil {
			fmt.Fprintf(os.Stderr, "WARN: delete session %s: %v\n", sessionID, err)
		}
	}()

	marker := fmt.Sprintf("ASYNC_DONE_%d", time.Now().UnixNano())
	command := longCommand(marker, cfg.duration)
	started := time.Now()
	result, err := sandbox.Process.ExecuteSessionCommand(ctx, sessionID, command, true, false)
	if err != nil {
		return fmt.Errorf("start async session command: %w", err)
	}

	commandID, ok := result["id"].(string)
	if !ok || commandID == "" {
		return fmt.Errorf("async response contained invalid command ID: %#v", result["id"])
	}
	fmt.Printf("Started command %s in %s; polling...\n", commandID, time.Since(started).Round(time.Millisecond))

	pollCtx, cancel := context.WithTimeout(ctx, cfg.duration+5*time.Minute)
	defer cancel()
	ticker := time.NewTicker(cfg.pollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-pollCtx.Done():
			return fmt.Errorf("waiting for async command: %w", pollCtx.Err())
		case <-ticker.C:
			status, err := sandbox.Process.GetSessionCommand(pollCtx, sessionID, commandID)
			if err != nil {
				return fmt.Errorf("poll async command: %w", err)
			}

			exitValue, finished := status["exitCode"]
			if !finished {
				fmt.Printf("  still running (%s elapsed)\n", time.Since(started).Round(time.Second))
				continue
			}

			exitCode, err := numericExitCode(exitValue)
			if err != nil {
				return err
			}
			logs, err := sandbox.Process.GetSessionCommandLogs(pollCtx, sessionID, commandID)
			if err != nil {
				return fmt.Errorf("get async command logs: %w", err)
			}

			stdout := logs.GetStdout()
			stderr := logs.GetStderr()
			fmt.Printf("Async command finished after %s with exit code %d\n", time.Since(started).Round(time.Millisecond), exitCode)
			fmt.Printf("stdout: %s\n", strings.TrimSpace(stdout))
			if strings.TrimSpace(stderr) != "" {
				fmt.Printf("stderr: %s\n", strings.TrimSpace(stderr))
			}
			if exitCode != 0 {
				return fmt.Errorf("async command exited with code %d", exitCode)
			}
			if !strings.Contains(stdout, marker) {
				return fmt.Errorf("async command logs did not contain completion marker %q", marker)
			}
			if time.Since(started) < time.Minute {
				return fmt.Errorf("async command unexpectedly completed before 60 seconds")
			}
			return nil
		}
	}
}

func longCommand(label string, duration time.Duration) string {
	seconds := duration.Seconds()
	return fmt.Sprintf("printf 'START %s\\n'; sleep %.3f; printf 'DONE %s\\n'", label, seconds, label)
}

func numericExitCode(value any) (int, error) {
	switch code := value.(type) {
	case int:
		return code, nil
	case int32:
		return int(code), nil
	case int64:
		return int(code), nil
	case float64:
		return int(code), nil
	default:
		return 0, fmt.Errorf("async response contained invalid exit code: %#v", value)
	}
}
