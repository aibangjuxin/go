package main

import "testing"

// TestGreet 最基本的函数：给输入，拿输出。
func TestGreet(t *testing.T) {
	cases := []struct {
		name string
		want string
	}{
		{"Le", "Hello, Le"},
		{"", "Hello, "},
		{"张三", "Hello, 张三"},
	}

	for _, c := range cases {
		if got := greet(c.name); got != c.want {
			t.Errorf("greet(%q) = %q, want %q", c.name, got, c.want)
		}
	}
}

// TestGreetWith 多返回值：两个都要，按顺序接。
func TestGreetWith(t *testing.T) {
	msg, n := greetWith("Le")

	if msg != "Hello, Le" {
		t.Errorf("msg = %q, want %q", msg, "Hello, Le")
	}
	if n != len("Hello, Le") {
		t.Errorf("n = %d, want %d", n, len("Hello, Le"))
	}
}

// TestCheckTitle 一次返回两个值：结果 + 原因。
func TestCheckTitle(t *testing.T) {
	cases := []struct {
		name   string
		title  string
		passed bool
		reason string
	}{
		{"有 CH 号", "feat(actions): add cr-prefix check for CH013456", true, "标题包含 CH 编号"},
		{"缺 CH 号", "release: pfb-gcp-v0.1.0", false, "标题缺少 CH 编号"},
		{"空标题", "", false, "标题为空"},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			passed, reason := checkTitle(c.title)

			if passed != c.passed {
				t.Errorf("passed = %v, want %v", passed, c.passed)
			}
			if reason != c.reason {
				t.Errorf("reason = %q, want %q", reason, c.reason)
			}
		})
	}
}

// TestHasCHNumber 单个 bool 返回值。
func TestHasCHNumber(t *testing.T) {
	if !hasCHNumber("CH013456") {
		t.Error("hasCHNumber(\"CH013456\") = false, want true")
	}
	if hasCHNumber("release: pfb-gcp-v0.1.0") {
		t.Error("hasCHNumber(\"release: ...\") = true, want false")
	}
}

// TestClassifyTitle 命名返回值 + 裸 return，结果必须和普通写法一致。
func TestClassifyTitle(t *testing.T) {
	cases := []struct {
		title  string
		passed bool
		reason string
	}{
		{"feat: CH013456", true, "标题包含 CH 编号"},
		{"fix: 修个 bug", false, "标题缺少 CH 编号"},
		{"", false, "标题为空"},
	}

	for _, c := range cases {
		passed, reason := classifyTitle(c.title)

		if passed != c.passed {
			t.Errorf("classifyTitle(%q) passed = %v, want %v", c.title, passed, c.passed)
		}
		if reason != c.reason {
			t.Errorf("classifyTitle(%q) reason = %q, want %q", c.title, reason, c.reason)
		}
	}
}

// TestRecord 无返回值的函数：通过副作用（改切片）留下结果。
func TestRecord(t *testing.T) {
	var results []string

	record(&results, "one")
	record(&results, "two")

	if len(results) != 2 {
		t.Fatalf("len(results) = %d, want 2", len(results))
	}
	if results[0] != "one" || results[1] != "two" {
		t.Errorf("results = %v, want [one two]", results)
	}
}

// TestApply 函数当参数传。
func TestApply(t *testing.T) {
	if got := apply(greet, "Le"); got != "Hello, Le" {
		t.Errorf("apply(greet, \"Le\") = %q, want %q", got, "Hello, Le")
	}
	if got := apply(shout, "Le"); got != "HELLO, LE" {
		t.Errorf("apply(shout, \"Le\") = %q, want %q", got, "HELLO, LE")
	}
}

// TestFunctionValue 函数赋给变量后，调用方式和原来一样。
func TestFunctionValue(t *testing.T) {
	f := greet

	if got := f("Le"); got != "Hello, Le" {
		t.Errorf("f(\"Le\") = %q, want %q", got, "Hello, Le")
	}
}

// TestReturnStopsFunction 记住：return 一执行，函数立刻结束。
//
// checkTitle 的第二个 return 永远不会执行 —— 所以缺 CH 号时，
// 绝不会同时返回两个原因。
func TestReturnStopsFunction(t *testing.T) {
	passed, reason := checkTitle("fix: 修个 bug")

	if passed {
		t.Error("passed = true, want false")
	}
	if reason == "标题包含 CH 编号" {
		t.Errorf("reason = %q, 不该出现「包含 CH 编号」", reason)
	}
}
