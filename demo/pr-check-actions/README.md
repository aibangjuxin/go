
---

## 9. 门禁配置：怎么关掉 / 怎么开回来

### 现在的状态

| 对象 | 状态 |
| :--- | :--- |
| `main` 的 classic branch protection | **已删除** → main 现在谁都能直接推，不需要 review、不需要 check |
| Ruleset `ip_verify`（id 6214824） | `enforcement = disabled`（本来就是没生效的） |
| 源码 | **全部保留**：`ip_validator.py` / `ip_validator.md` / `.github/workflows/validate-ip-list.yml` / `api_list.yaml` |

⚠️ 删掉的只是"**门禁**"，不是代码：
`validate-ip` 这个 workflow 仍然会在 PR 上跑、仍然会在 PR 上评论、校验失败仍然会红，
只是**不再拦住合并**。以后想让它重新有门禁效力，按下面一条命令开回来即可。

### 存档文件（就在本目录）

| 文件 | 内容 |
| :--- | :--- |
| `branch-protection-main.json` | 删除前的原始 GET 结果（存档用） |
| `branch-protection-main.restore.json` | **可以直接 PUT 回去**的最小 body（已实测有效） |
| `ruleset-ip_verify.json` | 那个 disabled 的 ruleset（以后想启用直接用它） |

### 以后想开回来（一条命令，已实测）

```bash
gh api -X PUT repos/aibangjuxin/go/branches/main/protection \
  --input demo/pr-check-actions/branch-protection-main.restore.json
```

PUT 上去之后是：required status check = `validate-ip`、strict = true、required reviews = 1。

### 或者走 UI

- **Rulesets**：Settings → Rules → Rulesets → `ip_verify` → "Set to active"
- **Classic**：Settings → Branches → Branch protection rules → Add rule（照 `restore.json` 填）

### 重新启用前先确认一件事

**确认 `validate-ip` 的 `paths` 过滤已经去掉**（本 PR 已经改好），
否则会再次出现"required check 永不上报 → PR 永远 Blocked"的老问题。

