package main

import "testing"

func TestGreet(t *testing.T) {
	tests := []struct {
		name string
		want string
	}{
		{name: "Le", want: "Hello, Le"},
		{name: "", want: "Hello, "},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := greet(tt.name); got != tt.want {
				t.Errorf("greet(%q) = %q, want %q", tt.name, got, tt.want)
			}
		})
	}
}
