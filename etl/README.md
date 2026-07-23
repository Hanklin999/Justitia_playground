# MOEX PDF → CSV ETL

This pipeline extracts the 113 and 114 Judicial Officer / Attorney First Examination PDFs into UTF-8 CSV files.

## Run

```bash
python -m venv .venv
# Windows: .venv\Scripts\activate
# macOS/Linux: source .venv/bin/activate
pip install -r etl/requirements.txt
python etl/extract_moex.py
```

## Replace or add PDFs

1. Put the question and official-answer PDFs under `data/raw/<ROC year>/`.
2. Add their metadata and paths to `etl/manifest.json`.
3. Run the extractor.
4. Review `data/processed/qa_report.csv` before importing anything.

The extractor fails closed when the number of questions, options, or official answers does not match the manifest.
