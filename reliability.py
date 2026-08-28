import os, sys
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import joblib
from sklearn.calibration import calibration_curve
from sklearn.metrics import brier_score_loss

sys.path.insert(0, "src/train")
from train import load_split, NUM_COLS, CAT_COLS, LABEL_COL

ART = os.environ.get("ARTIFACT_DIR", "artifacts/full")
art = joblib.load(os.path.join(ART, "model.joblib"))
model = art["model"]

print("Loading test split...")
df = load_split("test")
X = df[NUM_COLS + CAT_COLS]
y = df[LABEL_COL].astype(int).values

# calibrated probabilities
p_cal = model.predict_proba(X)[:, 1]

# raw (uncalibrated) probabilities from the frozen base pipeline
base = model.calibrated_classifiers_[0].estimator
p_raw = base.predict_proba(X)[:, 1]

b_raw = brier_score_loss(y, p_raw)
b_cal = brier_score_loss(y, p_cal)
base_rate = y.mean()
ceiling = base_rate * (1 - base_rate)


print(f"base rate          {base_rate:.4f}")
print(f"Brier ceiling      {ceiling:.4f}")
print(f"Brier raw          {b_raw:.4f}   (skill {1 - b_raw/ceiling:.2%})")
print(f"Brier calib        {b_cal:.4f}   (skill {1 - b_cal/ceiling:.2%})")

fig, ax = plt.subplots(figsize=(6.5, 6.5))
ax.plot([0, 1], [0, 1], "k--", lw=1, label="Perfect calibration")

for p, name, brier in [(p_raw, "Uncalibrated XGBoost", b_raw),
		       (p_cal, "Isotonic calibrated", b_cal)]:
    obs, pred = calibration_curve(y, p, n_bins=10, strategy="quantile")
    ax.plot(pred, obs, "o-", label=f"{name} (Brier {brier:.4f})")

ax.set_xlabel("Mean predicted probability of default")
ax.set_ylabel("Observed default rate")
ax.set_title("Reliability diagram, out-of-time test set")
ax.legend(loc="upper left")
ax.grid(alpha=0.3)
plt.tight_layout()

os.makedirs("docs", exist_ok=True)
plt.savefig("docs/reliability_diagram.png", dpi=150)
print("Saved docs/reliability_diagram.png")
