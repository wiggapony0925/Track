# app/ml — Machine learning models for Track arrival prediction.
#
# delay_model.py        — GradientBoosting pattern model (route × time × weather)
# recency_model.py      — Transit-style recency correction (per-stop weighted errors)
# train_model.py        — Bootstrap + retrain script (run directly: python -m app.ml.train_model)
# export_observations.py — Export live Redis recency data to CSV for retraining
#                          (run directly: python -m app.ml.export_observations)
