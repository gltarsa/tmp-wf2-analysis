BEGIN { FS="," }                            # Assumes "csv" format (with no spaces in column values)
NR == 1 { header = $0; next }               # skip the column headings
{ if (price[$1] < $2) price[$1] = $2 }      # Save the highest value
END {                                       # Dump the collection
  print header
  for (code in price) {
    printf "%s,%.2f\n", code, price[code]
    }
  }
