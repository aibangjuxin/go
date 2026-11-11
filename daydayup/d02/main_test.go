package main

import "testing"

func TestBuild(t *testing.T) {
	got := build()

	if got.Title != "feat: add cr-prefix check" {
		t.Errorf("Title = %q, want %q", got.Title, "feat: add cr-prefix check")
	}
	if got.Count != 0 {
		t.Errorf("Count = %d, want 0", got.Count)
	}
	if !got.Passed {
		t.Error("Passed = false, want true")
	}
}

// TestZeroValue 记住 Go 的核心特性：var 声明的值就是「零值」，不用初始化。
func TestZeroValue(t *testing.T) {
	var (
		s string
		i int
		b bool
		f float64
		p *int
	)

	if s != "" || i != 0 || b != false || f != 0 || p != nil {
		t.Errorf("零值不对: %q %d %v %v %v", s, i, b, f, p)
	}
}
