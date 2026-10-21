package main

import (
	"encoding/json"
	"log"
	"net/http"
)

type Greeting struct {
	Message string `json:"message"`
}

// greet answers /api/greet?name=Tide with a JSON greeting.
func greet(w http.ResponseWriter, r *http.Request) {
	name := r.URL.Query().Get("name")
	if name == "" {
		name = "world"
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(Greeting{Message: "Hello, " + name + "!"})
}

func main() {
	http.HandleFunc("/api/greet", greet)
	log.Println("listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}
