with open(r'backend\requirements.txt', 'r', encoding='utf-8-sig') as f:
    lines = f.readlines()
with open(r'backend\requirements.txt', 'w', encoding='utf-8') as f:
    f.writelines(lines)
