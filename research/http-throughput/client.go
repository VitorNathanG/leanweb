package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"os"
	"runtime"
	"slices"
	"sync"
	"syscall"
	"time"
)

type result struct {
	Workload       string         `json:"workload"`
	Concurrency    int            `json:"concurrency"`
	Seconds        float64        `json:"seconds"`
	Successes      int            `json:"successes"`
	Errors         int            `json:"errors"`
	ErrorSamples   map[string]int `json:"errorSamples"`
	RequestsPerSec float64        `json:"requestsPerSec"`
	MeanMs         float64        `json:"meanMs"`
	P50Ms          float64        `json:"p50Ms"`
	P95Ms          float64        `json:"p95Ms"`
	P99Ms          float64        `json:"p99Ms"`
	MaxMs          float64        `json:"maxMs"`
	ClientCPUs     float64        `json:"clientCPUs"`
	GoVersion      string         `json:"goVersion"`
}

type workerResult struct {
	latencies []int64
	errors    map[string]int
}

func cpuSeconds() float64 {
	var usage syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &usage); err != nil {
		panic(err)
	}
	return float64(usage.Utime.Sec+usage.Stime.Sec) +
		float64(usage.Utime.Usec+usage.Stime.Usec)/1e6
}

func request(address string, wire, expected []byte, contentType string) error {
	conn, err := net.DialTimeout("tcp4", address, 3*time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()
	if err = conn.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		return err
	}
	if _, err = io.Copy(conn, bytes.NewReader(wire)); err != nil {
		return err
	}
	response, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	mediaType, parameters, mediaErr := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if response.StatusCode != http.StatusOK || !response.Close ||
		response.ContentLength != int64(len(expected)) ||
		mediaErr != nil || mediaType != contentType || len(parameters) != 1 || parameters["charset"] != "utf-8" {
		return fmt.Errorf("unexpected response: status=%d close=%t length=%d type=%q",
			response.StatusCode, response.Close, response.ContentLength,
			response.Header.Get("Content-Type"))
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, int64(len(expected)+1)))
	if err != nil {
		return err
	}
	if !bytes.Equal(body, expected) {
		return fmt.Errorf("body mismatch: got %d bytes", len(body))
	}
	return nil
}

func main() {
	address := flag.String("address", "127.0.0.1:8080", "owned loopback server")
	workload := flag.String("workload", "health", "health or echo")
	concurrency := flag.Int("concurrency", 32, "closed-loop clients")
	duration := flag.Duration("duration", 8*time.Second, "measurement duration")
	flag.Parse()
	if *address != "127.0.0.1:8080" || *concurrency < 1 || *concurrency > 256 ||
		*duration <= 0 || *duration > 30*time.Second {
		panic("invalid benchmark bounds")
	}
	expected := []byte(`{"status":"ok"}`)
	contentType := "application/json"
	wire := []byte("GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
	if *workload == "echo" {
		expected = bytes.Repeat([]byte("x"), 1024)
		contentType = "text/plain"
		wire = append([]byte("POST /echo HTTP/1.1\r\nHost: localhost\r\n"+
			"Connection: close\r\nContent-Length: 1024\r\n\r\n"), expected...)
	} else if *workload != "health" {
		panic("unknown workload")
	}
	startGate := make(chan struct{})
	var ready sync.WaitGroup
	ready.Add(*concurrency)
	results := make(chan workerResult, *concurrency)
	var deadline time.Time
	for range *concurrency {
		go func() {
			local := workerResult{latencies: make([]int64, 0, 10000), errors: make(map[string]int)}
			ready.Done()
			<-startGate
			for time.Now().Before(deadline) {
				start := time.Now()
				err := request(*address, wire, expected, contentType)
				elapsed := time.Since(start).Nanoseconds()
				if err != nil {
					key := err.Error()
					if _, exists := local.errors[key]; !exists && len(local.errors) >= 8 {
						key = "other errors"
					}
					local.errors[key]++
				} else {
					local.latencies = append(local.latencies, elapsed)
				}
			}
			results <- local
		}()
	}
	ready.Wait()
	cpuStart := cpuSeconds()
	start := time.Now()
	deadline = start.Add(*duration)
	close(startGate)
	latencies := make([]int64, 0, 100000)
	output := result{Workload: *workload, Concurrency: *concurrency,
		ErrorSamples: make(map[string]int), GoVersion: runtime.Version()}
	for range *concurrency {
		local := <-results
		latencies = append(latencies, local.latencies...)
		for key, count := range local.errors {
			output.Errors += count
			output.ErrorSamples[key] += count
		}
	}
	output.Seconds = time.Since(start).Seconds()
	output.ClientCPUs = (cpuSeconds() - cpuStart) / output.Seconds
	output.Successes = len(latencies)
	output.RequestsPerSec = float64(output.Successes) / output.Seconds
	if len(latencies) > 0 {
		slices.Sort(latencies)
		quantile := func(percent int) float64 {
			index := (len(latencies)*percent+99)/100 - 1
			return float64(latencies[index]) / 1e6
		}
		var total int64
		for _, latency := range latencies {
			total += latency
		}
		output.MeanMs = float64(total) / float64(len(latencies)) / 1e6
		output.P50Ms, output.P95Ms, output.P99Ms = quantile(50), quantile(95), quantile(99)
		output.MaxMs = float64(latencies[len(latencies)-1]) / 1e6
	}
	if err := json.NewEncoder(os.Stdout).Encode(output); err != nil {
		panic(err)
	}
	if output.Errors > 0 || output.Successes == 0 {
		os.Exit(1)
	}
}
