// Command haku sends each user a daily Telegram digest of new Finnish job listings.
package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	log.Info("haku started")
	<-ctx.Done()
	log.Info("haku stopped")
}
