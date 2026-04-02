"""app/ml — Machine learning models for Track arrival prediction.

delay_model.py            — LightGBM pattern model (route x time x weather)
recency_model.py          — Transit-style recency correction (per-stop EWMA)
train_model.py            — Bootstrap + retrain pipeline (python -m app.ml.train_model)
data_loaders.py           — MTA open-data and CSV loaders for training
export_observations.py    — Export live Redis recency data to CSV for retraining
eta_accuracy_benchmark.py — Post-hoc ETA accuracy (Transit App methodology)
visualize.py              — 6-panel ML dashboard PNG (python -m app.ml.visualize)
"""

from __future__ import annotations
