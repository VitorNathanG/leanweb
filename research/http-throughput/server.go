package main

import (
	"io"
	"log"
	"net/http"
	"time"
)

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Content-Length", "15")
		w.Header().Set("Connection", "close")
		w.Header()["Date"] = nil
		_, _ = io.WriteString(w, `{"status":"ok"}`)
	})
	mux.HandleFunc("POST /echo", func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 65536))
		if err != nil {
			http.Error(w, "body error", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Connection", "close")
		w.Header()["Date"] = nil
		_, _ = w.Write(body)
	})
	server := &http.Server{Addr: "127.0.0.1:8080", Handler: mux, ReadTimeout: 5 * time.Second}
	server.SetKeepAlivesEnabled(false)
	log.Fatal(server.ListenAndServe())
}
