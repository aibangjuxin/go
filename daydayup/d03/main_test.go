package main

import "testing"

// TestCheckTitle 表驱动测试：把「if / else if / else」的三个分支都钉死。
func TestCheckTitle(t *testing.T) {
	cases := []struct {
		name   string
		title  string
		passed bool
		reason string
	}{
		{"有 CH 号", "feat(actions): add cr-prefix check for CH013456", true, "标题通过"},
		{"缺 CH 号", "fix: 修个 bug", false, "标题缺少 CH 号"},
		{"空标题", "", false, "标题为空"},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := checkTitle(c.title)

			if got.Passed != c.passed {
				t.Errorf("Passed = %v, want %v", got.Passed, c.passed)
			}
			if got.Reason != c.reason {
				t.Errorf("Reason = %q, want %q", got.Reason, c.reason)
			}
		})
	}
}

// TestCountChecks 三段式 for：循环次数必须精确，不能多也不能少。
func TestCountChecks(t *testing.T) {
	cases := []struct {
		times int
		want  int
	}{
		{0, 0},
		{1, 1},
		{3, 3},
		{5, 5},
	}

	for _, c := range cases {
		if got := countChecks(c.times); got != c.want {
			t.Errorf("countChecks(%d) = %d, want %d", c.times, got, c.want)
		}
	}
}

// TestRetryUntilPassed 条件式 for（while）：第二轮补上 CH 号就停，最多 3 次。
func TestRetryUntilPassed(t *testing.T) {
	passed, tries := retryUntilPassed("fix: 修个 bug", 3)

	if !passed {
		t.Error("passed = false, want true（第二轮就补上了 CH 号）")
	}
	if tries != 2 {
		t.Errorf("tries = %d, want 2", tries)
	}
}

// TestRetryStopsAtMax 复查次数用完还没通过，就该停 —— 不能死循环。
func TestRetryStopsAtMax(t *testing.T) {
	// maxTries = 1 时，第二轮「补 CH 号」不会发生，所以一定不通过
	passed, tries := retryUntilPassed("fix: 修个 bug", 1)

	if passed {
		t.Error("passed = true, want false")
	}
	if tries != 1 {
		t.Errorf("tries = %d, want 1", tries)
	}
}

// TestCheckAll for range：遍历一批标题，统计总数和通过数。
func TestCheckAll(t *testing.T) {
	titles := []string{
		"feat(actions): add cr-prefix check for CH013456",
		"fix: 修个 bug",
		"",
		"refactor: CH013456 拆分函数",
	}

	total, passed := checkAll(titles)

	if total != 4 {
		t.Errorf("total = %d, want 4", total)
	}
	if passed != 2 {
		t.Errorf("passed = %d, want 2", passed)
	}
}

// TestFindFirst break：找到第一个就返回。
func TestFindFirst(t *testing.T) {
	titles := []string{
		"fix: 修个 bug",
		"feat: add cr-prefix check for CH013456",
		"feat: another CH013457",
	}

	got, found := findFirst(titles)

	if !found {
		t.Fatal("found = false, want true")
	}
	if got != "feat: add cr-prefix check for CH013456" {
		t.Errorf("got = %q, want %q", got, "feat: add cr-prefix check for CH013456")
	}
}

// TestFindFirstNotFound 一个都没通过时，返回空 + false。
func TestFindFirstNotFound(t *testing.T) {
	got, found := findFirst([]string{"fix: 修个 bug", ""})

	if found {
		t.Error("found = true, want false")
	}
	if got != "" {
		t.Errorf("got = %q, want %q", got, "")
	}
}

// TestBraceTrap 记住：Go 的 if / else 大括号不能省。
//
// 下面这种写法在 Go 里是**编译错误**（syntax error），不是「只执行第一行」：
//
//	if true {
//	    t.Log("a")
//	} else { t.Log("b") }   // ← 少一个右大括号 → 编译不过
//
// 正确写法就是下面这样：大括号成对出现。
func TestBraceTrap(t *testing.T) {
	if true {
		t.Log("大括号写全了")
	} else {
		t.Log("这段永远不会执行")
	}
}

// TestEqualVsAssign 记住：== 是「比较」，= 是「赋值」。
//
// x == 1 是表达式，能放进 if 条件；
// x = 1 是赋值语句，在 if 条件里写它是编译错误（Go 不允许 if 条件是赋值）。
// 这个坑编译期就会报，不会带到线上。
func TestEqualVsAssign(t *testing.T) {
	x := 1

	if x == 1 { // ← 两个等号：比较
		t.Log("x 等于 1")
	}

	x = 2       // ← 一个等号：赋值
	if x != 1 { // ← 一个等号加感叹号：不等于
		t.Log("x 现在不等于 1")
	}
}
