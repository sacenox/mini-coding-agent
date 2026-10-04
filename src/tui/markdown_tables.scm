; Pipe tables. The grammar ships the nodes but its own highlights.scm names
; none of them, so the block pass has nothing to map; this file is added to it.
; Header cells take `text.title`, the capture nvim-treesitter gives them.
(pipe_table_header
  (pipe_table_cell) @text.title)

[
  (pipe_table_header)
  (pipe_table_row)
  (pipe_table_delimiter_row)
] "|" @punctuation.special

(pipe_table_delimiter_cell) @punctuation.special
