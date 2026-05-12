import pandas as pd

# Increase pandas display options to see everything
pd.set_option('display.max_columns', None)
pd.set_option('display.width', 1000)

try:
    df = pd.read_excel('c:/Users/hp/OneDrive/Desktop/accessibility_service/machine_learning/data/lsapp.xlsx')
    print("Columns:")
    print(df.columns.tolist())
    print("\nFirst 2 rows:")
    print(df.head(2).to_string())
except Exception as e:
    print(f"Error reading excel: {e}")
