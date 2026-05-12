import pandas as pd
df = pd.read_excel('c:/Users/hp/OneDrive/Desktop/accessibility_service/machine_learning/data/lsapp.xlsx', nrows=5)
with open('c:/Users/hp/OneDrive/Desktop/accessibility_service/tmp_cols.txt', 'w', encoding='utf-8') as f:
    f.write("Columns:\n")
    f.write(", ".join(df.columns))
    f.write("\n\nData:\n")
    f.write(df.to_string())
