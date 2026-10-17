PROGRAM = main

all: $(PROGRAM).hex

$(PROGRAM).hex: $(PROGRAM).asm

	avra -fI $<

clean:

	rm -f $(PROGRAM).hex $(PROGRAM).obj $(PROGRAM).eep.hex
