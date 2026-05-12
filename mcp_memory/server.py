from mcp.server.fastmcp import FastMCP
import os

mcp = FastMCP("MemoryServer")

# Get the project root directory (parent of mcp_memory/)
project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTEXT_DIR = os.path.join(project_root, ".ai_context")

def ensure_context_dir():
    if not os.path.exists(CONTEXT_DIR):
        os.makedirs(CONTEXT_DIR)

@mcp.tool()
def save_context(filename: str, content: str) -> str:
    """Saves markdown content to the .ai_context/ directory."""
    ensure_context_dir()
    filepath = os.path.join(CONTEXT_DIR, filename)
    with open(filepath, "w", encoding="utf-8") as f:
        f.write(content)
    return f"Successfully saved context to {filename}"

@mcp.tool()
def read_context(filename: str) -> str:
    """Reads context from the .ai_context/ directory."""
    filepath = os.path.join(CONTEXT_DIR, filename)
    if not os.path.exists(filepath):
        return f"Error: File {filename} does not exist in .ai_context/"
    with open(filepath, "r", encoding="utf-8") as f:
        return f.read()

@mcp.tool()
def list_contexts() -> str:
    """Lists files in the .ai_context/ directory."""
    if not os.path.exists(CONTEXT_DIR):
        return "No contexts found (.ai_context/ directory does not exist)."
    
    files = os.listdir(CONTEXT_DIR)
    if not files:
        return "No context files found."
        
    return "Context files:\n- " + "\n- ".join(files)

if __name__ == "__main__":
    mcp.run()
